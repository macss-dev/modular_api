import 'dart:async';
import 'dart:convert';

import 'package:gql/ast.dart';
import 'package:gql/language.dart' as gql;
import 'package:leto/dataloader.dart';
import 'package:leto/leto.dart';
import 'package:leto_schema/leto_schema.dart';
import 'package:leto_schema/utilities.dart' as leto_schema;
import 'package:leto_schema/validate_rules.dart';
import 'package:leto_shelf/leto_shelf.dart';
import 'package:modular_api/src/core/plugin.dart';
import 'package:modular_api/src/graphql/catalog/graphql_catalog_builder.dart';
import 'package:modular_api/src/graphql/read/sql_read_contract.dart';
import 'package:modular_api/src/graphql/read/sqlserver_read_compiler.dart';
import 'package:modular_api/src/graphql/runtime/graphql_runtime_health.dart';
import 'package:modular_api/src/graphql/runtime/graphql_runtime_options.dart';
import 'package:shelf/shelf.dart';

const _graphQlPluginHostRange = '>=0.1.0 <0.2.0';
const _graphQlRequestIdContextKey = 'modular_api.graphql.requestId';
const _graphQlLoggerContextKey = 'modular_api.graphql.logger';
const _graphQlTotalCountThunkKey = r'$modular_api.graphql.totalCount';
const _requestIdHeader = 'x-request-id';
const _tenantIdHeader = 'x-tenant-id';
const _principalHeader = 'x-principal';

final _relationLoadersRef = ScopedRef.local(
  (_) => <String, DataLoader<_RelationParentKey, List<Map<String, Object?>>, String>>{},
  name: 'modular_api.graphql.relationLoaders',
);

final class _PreparedGraphqlRuntime {
  const _PreparedGraphqlRuntime({required this.catalog, required this.schema});

  final GraphqlCatalog catalog;
  final GraphQLSchema schema;
}

Future<Plugin> buildGraphqlRuntimePlugin({
  required GraphqlOptions options,
  required GraphqlRuntimeState runtimeState,
}) async {
  _validateGraphqlOptions(options);

  final catalog = await _buildCatalog(options);
  final preparedRuntime = _buildGraphQlRuntime(catalog, options);

  return _GraphqlRuntimePlugin(
    options: options,
    runtimeState: runtimeState,
    preparedRuntime: preparedRuntime,
  );
}

void _validateGraphqlOptions(GraphqlOptions options) {
  if (options.maxDepth <= 0) {
    throw PluginHostError(
      'PLUGIN_VALIDATION_FAILED',
      'GraphQL maxDepth must be greater than zero.',
      resourceId: 'graphql.maxDepth',
    );
  }

  if (options.maxComplexity <= 0) {
    throw PluginHostError(
      'PLUGIN_VALIDATION_FAILED',
      'GraphQL maxComplexity must be greater than zero.',
      resourceId: 'graphql.maxComplexity',
    );
  }

  if (options.defaultLimit < 0) {
    throw PluginHostError(
      'PLUGIN_VALIDATION_FAILED',
      'GraphQL defaultLimit must be non-negative.',
      resourceId: 'graphql.defaultLimit',
    );
  }

  if (options.maxLimit <= 0) {
    throw PluginHostError(
      'PLUGIN_VALIDATION_FAILED',
      'GraphQL maxLimit must be greater than zero.',
      resourceId: 'graphql.maxLimit',
    );
  }

  if (options.defaultLimit > options.maxLimit) {
    throw PluginHostError(
      'PLUGIN_VALIDATION_FAILED',
      'GraphQL defaultLimit cannot exceed maxLimit.',
      resourceId: 'graphql.pagination',
    );
  }
}

Future<GraphqlCatalog> _buildCatalog(GraphqlOptions options) async {
  try {
    final catalog = await Future<GraphqlCatalog>.sync(options.catalogFactory);
    final blockingDiagnostics = catalog.diagnostics
        .where((diagnostic) =>
            diagnostic.severity == GraphqlCatalogDiagnosticSeverity.error)
        .toList(growable: false);

    if (blockingDiagnostics.isNotEmpty) {
      final message = blockingDiagnostics
          .map((diagnostic) => '${diagnostic.code}: ${diagnostic.message}')
          .join('; ');
      throw PluginHostError(
        'PLUGIN_VALIDATION_FAILED',
        'GraphQL catalog contains blocking diagnostics: $message',
        resourceId: 'graphql.catalog',
      );
    }

    return catalog;
  } on PluginHostError {
    rethrow;
  } catch (error) {
    throw PluginHostError(
      'PLUGIN_VALIDATION_FAILED',
      'GraphQL catalog construction failed: $error',
      resourceId: 'graphql.catalog',
    );
  }
}

_PreparedGraphqlRuntime _buildGraphQlRuntime(
  GraphqlCatalog catalog,
  GraphqlOptions options,
) {
  try {
    final sdl = options.sdlFactory(catalog);
    final schema = leto_schema.buildSchema(sdl);
    return _PreparedGraphqlRuntime(
      catalog: catalog,
      schema: schema,
    );
  } catch (error) {
    throw PluginHostError(
      'PLUGIN_VALIDATION_FAILED',
      'GraphQL schema construction failed: $error',
      resourceId: 'graphql.schema',
    );
  }
}

final class _GraphqlRuntimePlugin implements Plugin, ValidatingPlugin, ShutdownAwarePlugin {
  _GraphqlRuntimePlugin({
    required this.options,
    required this.runtimeState,
    required this.preparedRuntime,
  });

  final GraphqlOptions options;
  final GraphqlRuntimeState runtimeState;
  final _PreparedGraphqlRuntime preparedRuntime;

  SqlReadExecutor? _resolvedExecutor;
  String? _executorValidationMessage;
  String? _executorValidationResourceId;
  Handler? _handler;

  @override
  PluginManifest get manifest => const PluginManifest(
        id: 'modular_api.graphql',
        displayName: 'GraphQL Runtime Plugin',
        version: '0.1.0',
        hostApiVersion: _graphQlPluginHostRange,
      );

  @override
  void setup(PluginHost host) {
    _resolvedExecutor = options.executor;
    if (_resolvedExecutor == null) {
      final capabilityId = options.resolvedExecutionCapabilityId;
      final capability = host.resolveCapability(capabilityId);
      if (capability == null) {
        _executorValidationMessage = 'Missing GraphQL read executor capability: $capabilityId';
        _executorValidationResourceId = capabilityId;
      } else if (capability.value is! SqlReadExecutor) {
        _executorValidationMessage = 'Capability $capabilityId does not expose a SqlReadExecutor.';
        _executorValidationResourceId = capabilityId;
      } else {
        _resolvedExecutor = capability.value as SqlReadExecutor;
      }
    }

    if (_resolvedExecutor != null) {
      final dispatcher = SqlCatalogReadDispatcher(
        compiler: const SqlServerReadCompiler(),
        executor: _resolvedExecutor!,
      );
      _bindResolvers(
        schema: preparedRuntime.schema,
        catalog: preparedRuntime.catalog,
        dispatcher: dispatcher,
        options: options,
      );
      final graphQL = GraphQL(
        preparedRuntime.schema,
        introspect: options.introspectionEnabled,
        validate: true,
        defaultFieldResolver: _defaultFieldResolver,
        customValidationRules: [
          queryComplexityRuleBuilder(
            maxComplexity: options.maxComplexity,
            maxDepth: options.maxDepth,
          ),
        ],
      );
      _handler = graphQLHttp(graphQL);
    }

    host.registerRoute(
      PluginRoute(
        id: 'graphql.endpoint.get',
        method: 'GET',
        path: '/graphql',
        visibility: 'custom',
        handler: _handleRequest,
      ),
    );
    host.registerRoute(
      PluginRoute(
        id: 'graphql.endpoint.post',
        method: 'POST',
        path: '/graphql',
        visibility: 'custom',
        handler: _handleRequest,
      ),
    );

    if (_resolvedExecutor != null) {
      runtimeState.markReady();
    }
  }

  Future<Response> _handleRequest(PluginRequestContext context) async {
    final handler = _handler;
    if (handler == null) {
      throw StateError('GraphQL runtime handler is not initialized.');
    }

    final request = _toShelfRequest(context);
    await _emitEvent(
      context,
      GraphqlRequestEvent(
        phase: GraphqlRequestPhase.started,
        requestId: context.requestId,
        method: context.method,
        path: context.path,
      ),
    );
    context.logger?.info(
      'graphql request started',
      fields: <String, dynamic>{
        'request_id': context.requestId,
        'method': context.method,
        'path': context.path,
      },
    );

    try {
      final depthResponse = _enforceDepthLimit(context, options.maxDepth);
      if (depthResponse != null) {
        await _emitEvent(
          context,
          GraphqlRequestEvent(
            phase: GraphqlRequestPhase.completed,
            requestId: context.requestId,
            method: context.method,
            path: context.path,
            statusCode: depthResponse.statusCode,
          ),
        );
        context.logger?.info(
          'graphql request completed',
          fields: <String, dynamic>{
            'request_id': context.requestId,
            'method': context.method,
            'path': context.path,
            'status': depthResponse.statusCode,
          },
        );
        return depthResponse;
      }

      final response = await handler(request);
      await _emitEvent(
        context,
        GraphqlRequestEvent(
          phase: GraphqlRequestPhase.completed,
          requestId: context.requestId,
          method: context.method,
          path: context.path,
          statusCode: response.statusCode,
        ),
      );
      context.logger?.info(
        'graphql request completed',
        fields: <String, dynamic>{
          'request_id': context.requestId,
          'method': context.method,
          'path': context.path,
          'status': response.statusCode,
        },
      );
      return response;
    } catch (error) {
      await _emitEvent(
        context,
        GraphqlRequestEvent(
          phase: GraphqlRequestPhase.completed,
          requestId: context.requestId,
          method: context.method,
          path: context.path,
          statusCode: 500,
        ),
      );
      context.logger?.warning(
        'graphql request failed',
        fields: <String, dynamic>{
          'request_id': context.requestId,
          'method': context.method,
          'path': context.path,
          'status': 500,
          'error': error.toString(),
        },
      );
      rethrow;
    }
  }

  Future<void> _emitEvent(
    PluginRequestContext context,
    GraphqlRequestEvent event,
  ) async {
    final onEvent = options.onEvent;
    if (onEvent == null) {
      return;
    }

    try {
      await Future<void>.sync(() => onEvent(event));
    } catch (error) {
      context.logger?.warning(
        'graphql telemetry hook failed',
        fields: <String, dynamic>{
          'request_id': context.requestId,
          'path': context.path,
          'error': error.toString(),
        },
      );
    }
  }

  @override
  List<PluginValidationResult> validate(PluginHost host) {
    if (_resolvedExecutor != null) {
      return const <PluginValidationResult>[];
    }

    return <PluginValidationResult>[
      PluginValidationResult(
        code: 'PLUGIN_VALIDATION_FAILED',
        message: _executorValidationMessage ??
            'GraphQL runtime requires a SqlReadExecutor before startup.',
        pluginId: manifest.id,
        resourceId:
            _executorValidationResourceId ?? options.resolvedExecutionCapabilityId,
      ),
    ];
  }

  @override
  Future<void> shutdown() async {
    runtimeState.markDisabled();
    if (options.executor != null) {
      await options.executor!.close();
    }
  }
}

Response? _enforceDepthLimit(PluginRequestContext context, int maxDepth) {
  for (final query in _requestQueries(context)) {
    try {
      final document = gql.parseString(query);
      final depth = _documentDepth(document);
      if (depth > maxDepth) {
        return Response.ok(
          jsonEncode(
            <String, Object?>{
              'errors': <Object?>[
                <String, Object?>{
                  'message':
                      'Maximum operation depth of $maxDepth reached. Operation depth: $depth.',
                  'extensions': <String, Object?>{
                    'validationError': <String, Object?>{
                      'spec': 'https://github.com/juancastillo0/leto#query-complexity',
                      'code': 'queryDepthComplexity',
                    },
                  },
                },
              ],
            },
          ),
          headers: const <String, String>{'content-type': 'application/json'},
        );
      }
    } catch (_) {
      continue;
    }
  }
  return null;
}

List<String> _requestQueries(PluginRequestContext context) {
  if (context.body is Map<Object?, Object?>) {
    final query = (context.body as Map<Object?, Object?>)['query'];
    if (query is String && query.isNotEmpty) {
      return <String>[query];
    }
  }
  if (context.body is List<Object?>) {
    return (context.body as List<Object?>)
        .whereType<Map<Object?, Object?>>()
        .map((payload) => payload['query'])
        .whereType<String>()
        .where((query) => query.isNotEmpty)
        .toList(growable: false);
  }
  final query = context.query['query'];
  if (query != null && query.isNotEmpty) {
    return <String>[query];
  }
  return const <String>[];
}

int _documentDepth(DocumentNode document) {
  var maxDepth = 0;

  void visitSelectionSet(SelectionSetNode selectionSet, int currentDepth) {
    for (final selection in selectionSet.selections) {
      if (selection is FieldNode) {
        final nextDepth = currentDepth + 1;
        if (nextDepth > maxDepth) {
          maxDepth = nextDepth;
        }
        final childSelectionSet = selection.selectionSet;
        if (childSelectionSet != null) {
          visitSelectionSet(childSelectionSet, nextDepth);
        }
      } else if (selection is FragmentSpreadNode) {
        final fragment = document.definitions
            .whereType<FragmentDefinitionNode>()
            .firstWhere((candidate) => candidate.name.value == selection.name.value);
        visitSelectionSet(fragment.selectionSet, currentDepth);
      } else if (selection is InlineFragmentNode) {
        visitSelectionSet(selection.selectionSet, currentDepth);
      }
    }
  }

  for (final definition in document.definitions.whereType<OperationDefinitionNode>()) {
    visitSelectionSet(definition.selectionSet, 0);
  }

  return maxDepth;
}

Request _toShelfRequest(PluginRequestContext context) {
  final queryParameters = context.query.isEmpty ? null : context.query;
  final normalizedPath = context.path.startsWith('/')
      ? context.path
      : '/${context.path}';
  final uri = Uri(
    scheme: 'http',
    host: 'localhost',
    path: normalizedPath,
    queryParameters: queryParameters,
  );
  final body = switch (context.body) {
    null => null,
    String value => value,
    _ => context.body is List<int> ? context.body as List<int> : jsonEncode(context.body),
  };

  return Request(
    context.method,
    uri,
    headers: context.headers,
    body: body,
    context: <String, Object>{
      _graphQlRequestIdContextKey: context.requestId,
      if (context.logger != null) _graphQlLoggerContextKey: context.logger!,
    },
  );
}

void _bindResolvers({
  required GraphQLSchema schema,
  required GraphqlCatalog catalog,
  required SqlCatalogReadDispatcher dispatcher,
  required GraphqlOptions options,
}) {
  final queryType = schema.queryType;
  if (queryType == null) {
    throw PluginHostError(
      'PLUGIN_VALIDATION_FAILED',
      'GraphQL schema does not define a Query root type.',
      resourceId: 'graphql.schema',
    );
  }

  for (final object in catalog.objects) {
    if (object.graphql.itemField case final String itemField) {
      _replaceFieldResolver(
        queryType,
        itemField,
        FieldResolver<Object?, Object?>(
          (parent, ctx) => _resolveItem(
            ctx,
            catalog: catalog,
            object: object,
            dispatcher: dispatcher,
          ),
        ),
      );
    }

    _replaceFieldResolver(
      queryType,
      object.graphql.collectionField,
      FieldResolver<Object?, Object?>(
        (parent, ctx) => _resolveCollection(
          ctx,
          catalog: catalog,
          object: object,
          dispatcher: dispatcher,
          options: options,
        ),
      ),
    );

    final objectType = schema.getType(object.graphql.typeName);
    if (objectType is GraphQLObjectType) {
      _bindRelationResolvers(
        objectType: objectType as GraphQLObjectType<Object?>,
        catalog: catalog,
        object: object,
        dispatcher: dispatcher,
        options: options,
      );
    }

    final listType = schema.getType('${object.graphql.typeName}List');
    if (listType is GraphQLObjectType) {
      _replaceFieldResolver(
        listType as GraphQLObjectType<Object?>,
        'totalCount',
        FieldResolver<Object?, Object?>(
          (parent, ctx) async {
            if (parent is! Map<Object?, Object?>) {
              return 0;
            }
            final thunk = parent[_graphQlTotalCountThunkKey];
            if (thunk is Future<int> Function()) {
              return thunk();
            }
            return 0;
          },
        ),
      );
    }
  }
}

void _bindRelationResolvers({
  required GraphQLObjectType<Object?> objectType,
  required GraphqlCatalog catalog,
  required GraphqlPublishedObject object,
  required SqlCatalogReadDispatcher dispatcher,
  required GraphqlOptions options,
}) {
  for (final relation in object.relations) {
    _replaceFieldResolver(
      objectType,
      relation.name,
      FieldResolver<Object?, Object?>(
        (parent, ctx) => _resolveRelation(
          parent,
          ctx,
          catalog: catalog,
          sourceObject: object,
          relation: relation,
          dispatcher: dispatcher,
          options: options,
        ),
      ),
    );
  }
}

void _replaceFieldResolver(
  GraphQLObjectType<Object?> type,
  String fieldName,
  FieldResolver<Object?, Object?> resolver,
) {
  final index = type.fields.indexWhere((field) => field.name == fieldName);
  if (index < 0) {
    return;
  }

  final original = type.fields[index];
  type.fields[index] = GraphQLObjectField<Object?, Object?, Object?>(
    original.name,
    original.type,
    inputs: original.inputs,
    resolve: resolver,
    subscribe: original.subscribe,
    deprecationReason: original.deprecationReason,
    description: original.description,
    attachments: original.attachments,
    astNode: original.astNode,
  );
}

Future<Object?> _resolveItem(
  Ctx<Object?> ctx, {
  required GraphqlCatalog catalog,
  required GraphqlPublishedObject object,
  required SqlCatalogReadDispatcher dispatcher,
}) async {
  final rawKey = ctx.args['key'];
  if (rawKey is! Map<Object?, Object?>) {
    throw _graphqlValidationError(
      ctx,
      'graphql.key',
      'GraphQL item queries require a key input object.',
    );
  }

  final selection = ctx.lookahead()?.forObject;
  final projectedFields = _projectedFieldsForObject(object, selection);
  final rowSet = await dispatcher.readItem(
    catalog: catalog,
    selection: SqlItemSelection(
      objectId: object.id,
      projectedFields: projectedFields,
      key: Map<String, Object?>.from(rawKey),
    ),
    context: _buildExecutionContext(ctx),
  );

  if (rowSet.rows.isEmpty) {
    return null;
  }
  return rowSet.rows.first;
}

Future<Object?> _resolveCollection(
  Ctx<Object?> ctx, {
  required GraphqlCatalog catalog,
  required GraphqlPublishedObject object,
  required SqlCatalogReadDispatcher dispatcher,
  required GraphqlOptions options,
}) async {
  final envelopeSelection = ctx.lookahead()?.forObject;
  final itemSelection = envelopeSelection?.nested('items')?.forObject;
  final wantsTotalCount = envelopeSelection?.contains('totalCount') ?? false;
  final filter = _parseFilter(object, ctx.args['filter'], ctx);
  final orderBy = _parseOrderBy(object, ctx.args['orderBy'], ctx);
  final page = _parsePage(object, ctx.args['page'], ctx, options);

  var items = const <Map<String, Object?>>[];
  if (itemSelection != null && page.limit > 0) {
    final rowSet = await dispatcher.readCollection(
      catalog: catalog,
      selection: SqlCollectionSelection(
        objectId: object.id,
        projectedFields: _projectedFieldsForObject(object, itemSelection),
        filter: filter,
        orderBy: orderBy,
        page: page,
      ),
      context: _buildExecutionContext(ctx),
    );
    items = rowSet.rows;
  }

  Future<int> Function()? totalCountThunk;
  if (wantsTotalCount) {
    totalCountThunk = () async {
      final rowSet = await dispatcher.readCount(
        catalog: catalog,
        selection: SqlCountSelection(objectId: object.id, filter: filter),
        context: _buildExecutionContext(ctx),
      );
      return _extractTotalCount(rowSet);
    };
  }

  return <String, Object?>{
    'items': items,
    if (totalCountThunk != null) _graphQlTotalCountThunkKey: totalCountThunk,
  };
}

Future<Object?> _resolveRelation(
  Object? parent,
  Ctx<Object?> ctx, {
  required GraphqlCatalog catalog,
  required GraphqlPublishedObject sourceObject,
  required GraphqlCatalogRelation relation,
  required SqlCatalogReadDispatcher dispatcher,
  required GraphqlOptions options,
}) async {
  if (parent is! Map<Object?, Object?>) {
    return relation.cardinality == GraphqlCatalogRelationCardinality.many
        ? const <Map<String, Object?>>[]
        : null;
  }

  final targetObject = _objectById(catalog, relation.target);
  final selection = ctx.lookahead()?.forObject;
  final requiredPublicFields = relation.targetFields
      .map((column) => _fieldByColumn(targetObject, column).publicName)
      .toList(growable: false);
  final projectedFields = _projectedFieldsForObject(
    targetObject,
    selection,
    requiredPublicFields: requiredPublicFields,
  );
  final parentKeyValues = _relationParentValues(
    sourceObject: sourceObject,
    relation: relation,
    parent: parent,
  );
  final loader = _relationLoader(
    ctx,
    catalog: catalog,
    sourceObject: sourceObject,
    targetObject: targetObject,
    relation: relation,
    projectedFields: projectedFields,
    dispatcher: dispatcher,
  );
  final rows = await loader.load(
    _RelationParentKey(
      sourceObjectId: sourceObject.id,
      relationName: relation.name,
      values: parentKeyValues,
    ),
  );

  if (relation.cardinality == GraphqlCatalogRelationCardinality.many) {
    return rows;
  }
  return rows.isEmpty ? null : rows.first;
}

DataLoader<_RelationParentKey, List<Map<String, Object?>>, String> _relationLoader(
  Ctx<Object?> ctx, {
  required GraphqlCatalog catalog,
  required GraphqlPublishedObject sourceObject,
  required GraphqlPublishedObject targetObject,
  required GraphqlCatalogRelation relation,
  required List<String> projectedFields,
  required SqlCatalogReadDispatcher dispatcher,
}) {
  final loaders = _relationLoadersRef.get(ctx);
  final loaderId = [sourceObject.id, relation.name, projectedFields.join(',')].join('|');
  final existing = loaders[loaderId];
  if (existing != null) {
    return existing;
  }

  final loader = DataLoader<_RelationParentKey, List<Map<String, Object?>>, String>(
    (keys) async {
      final rowSet = await dispatcher.readRelationBatch(
        catalog: catalog,
        selection: SqlRelationBatchSelection(
          sourceObjectId: sourceObject.id,
          relationName: relation.name,
          projectedFields: projectedFields,
          parentKeys: keys.map((key) => key.values).toList(growable: false),
        ),
        context: _buildExecutionContext(ctx),
      );

      final groupedRows = <String, List<Map<String, Object?>>>{};
      for (final row in rowSet.rows) {
        final cacheKey = _targetRowCacheKey(
          targetObject: targetObject,
          relation: relation,
          row: row,
        );
        groupedRows.putIfAbsent(cacheKey, () => <Map<String, Object?>>[]).add(row);
      }

      return keys
          .map((key) => groupedRows[key.cacheKey] ?? const <Map<String, Object?>>[])
          .toList(growable: false);
    },
    DataLoaderOptions<_RelationParentKey, List<Map<String, Object?>>, String>(
      cacheKeyFn: (key) => key.cacheKey,
    ),
  );

  loaders[loaderId] = loader;
  return loader;
}

ReadExecutionContext _buildExecutionContext(Ctx<Object?> ctx) {
  final request = ctx.request;
  return ReadExecutionContext(
    requestId: _headerValue(request, _requestIdHeader) ??
        request.context[_graphQlRequestIdContextKey] as String?,
    tenantId: _headerValue(request, _tenantIdHeader),
    principal: _headerValue(request, _principalHeader),
    telemetry: request.context[_graphQlLoggerContextKey],
  );
}

String? _headerValue(Request request, String name) {
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == name) {
      return entry.value;
    }
  }
  return null;
}

FutureOr<Object?> _defaultFieldResolver(Object? parent, Ctx ctx) {
  if (parent is Map<String, Object?>) {
    return parent[ctx.field.name];
  }
  if (parent is Map<Object?, Object?>) {
    return parent[ctx.field.name];
  }
  return null;
}

List<String> _projectedFieldsForObject(
  GraphqlPublishedObject object,
  PossibleSelectionsObject? selection, {
  Iterable<String> requiredPublicFields = const <String>[],
}) {
  final projected = <String>{
    ...requiredPublicFields,
    ...object.identity.fields.map(
      (column) => _fieldByColumn(object, column).publicName,
    ),
  };

  if (selection != null) {
    for (final fieldName in selection.map.keys) {
      if (object.fields.any((field) => field.publicName == fieldName)) {
        projected.add(fieldName);
      }
    }
    for (final relation in object.relations) {
      if (!selection.contains(relation.name)) {
        continue;
      }
      for (final column in relation.sourceFields) {
        projected.add(_fieldByColumn(object, column).publicName);
      }
    }
  }

  return object.fields
      .where((field) => projected.contains(field.publicName))
      .map((field) => field.publicName)
      .toList(growable: false);
}

SqlFilterNode? _parseFilter(
  GraphqlPublishedObject object,
  Object? raw,
  Ctx<Object?> ctx,
) {
  if (raw == null) {
    return null;
  }
  if (raw is! Map<Object?, Object?>) {
    throw _graphqlValidationError(
      ctx,
      'graphql.filter',
      'GraphQL filter input must be an object.',
    );
  }

  final nodes = <SqlFilterNode>[];
  for (final entry in raw.entries) {
    final key = entry.key?.toString();
    if (key == null) {
      continue;
    }

    switch (key) {
      case 'and':
        final children = (entry.value as List<Object?>? ?? const <Object?>[])
            .map((value) => _parseFilter(object, value, ctx))
            .whereType<SqlFilterNode>()
            .toList(growable: false);
        if (children.isNotEmpty) {
          nodes.add(SqlFilterGroup.and(children));
        }
        continue;
      case 'or':
        final children = (entry.value as List<Object?>? ?? const <Object?>[])
            .map((value) => _parseFilter(object, value, ctx))
            .whereType<SqlFilterNode>()
            .toList(growable: false);
        if (children.isNotEmpty) {
          nodes.add(SqlFilterGroup.or(children));
        }
        continue;
      case 'not':
        final child = _parseFilter(object, entry.value, ctx);
        if (child != null) {
          nodes.add(SqlFilterGroup.not(child));
        }
        continue;
      default:
        final field = _fieldByPublicName(object, key);
        if (!field.filterable) {
          throw _graphqlValidationError(
            ctx,
            'graphql.filter',
            'Field ${field.publicName} is not filterable.',
          );
        }
        if (entry.value is! Map<Object?, Object?>) {
          throw _graphqlValidationError(
            ctx,
            'graphql.filter',
            'Filter operators for ${field.publicName} must be an object.',
          );
        }
        final conditions = <SqlFilterNode>[];
        for (final operatorEntry in (entry.value as Map<Object?, Object?>).entries) {
          final operatorName = operatorEntry.key?.toString();
          if (operatorName == null) {
            continue;
          }
          conditions.add(
            SqlFilterCondition(
              field: field.publicName,
              operator: _filterOperator(operatorName, ctx),
              value: operatorEntry.value,
            ),
          );
        }
        if (conditions.length == 1) {
          nodes.add(conditions.single);
        } else if (conditions.isNotEmpty) {
          nodes.add(SqlFilterGroup.and(conditions));
        }
    }
  }

  if (nodes.isEmpty) {
    return null;
  }
  return nodes.length == 1 ? nodes.single : SqlFilterGroup.and(nodes);
}

SqlFilterOperator _filterOperator(String name, Ctx<Object?> ctx) {
  switch (name) {
    case 'eq':
      return SqlFilterOperator.eq;
    case 'ne':
      return SqlFilterOperator.ne;
    case 'in':
      return SqlFilterOperator.inList;
    case 'lt':
      return SqlFilterOperator.lt;
    case 'lte':
      return SqlFilterOperator.lte;
    case 'gt':
      return SqlFilterOperator.gt;
    case 'gte':
      return SqlFilterOperator.gte;
    case 'isNull':
      return SqlFilterOperator.isNull;
    case 'contains':
      return SqlFilterOperator.contains;
    case 'startsWith':
      return SqlFilterOperator.startsWith;
    case 'endsWith':
      return SqlFilterOperator.endsWith;
    default:
      throw _graphqlValidationError(
        ctx,
        'graphql.filter',
        'Unsupported filter operator $name.',
      );
  }
}

List<SqlOrderByClause> _parseOrderBy(
  GraphqlPublishedObject object,
  Object? raw,
  Ctx<Object?> ctx,
) {
  if (raw == null) {
    return const <SqlOrderByClause>[];
  }
  if (raw is! List<Object?>) {
    throw _graphqlValidationError(
      ctx,
      'graphql.orderBy',
      'GraphQL orderBy input must be a list.',
    );
  }

  return raw.map((value) {
    if (value is! Map<Object?, Object?>) {
      throw _graphqlValidationError(
        ctx,
        'graphql.orderBy',
        'Each orderBy entry must be an object.',
      );
    }

    final fieldName = value['field']?.toString();
    final direction = value['direction']?.toString();
    if (fieldName == null || direction == null) {
      throw _graphqlValidationError(
        ctx,
        'graphql.orderBy',
        'Each orderBy entry must define field and direction.',
      );
    }

    final field = _fieldByPublicName(object, fieldName);
    if (!field.sortable) {
      throw _graphqlValidationError(
        ctx,
        'graphql.orderBy',
        'Field ${field.publicName} is not sortable.',
      );
    }

    return SqlOrderByClause(
      field: field.publicName,
      direction: direction == 'DESC' ? SqlSortDirection.desc : SqlSortDirection.asc,
    );
  }).toList(growable: false);
}

SqlPage _parsePage(
  GraphqlPublishedObject object,
  Object? raw,
  Ctx<Object?> ctx,
  GraphqlOptions options,
) {
  final effectiveMax = object.capabilities.pagination.maxLimit < options.maxLimit
      ? object.capabilities.pagination.maxLimit
      : options.maxLimit;
  final objectDefault = object.capabilities.pagination.defaultLimit;
  final narrowedDefault = objectDefault < options.defaultLimit
      ? objectDefault
      : options.defaultLimit;
  final effectiveDefault = narrowedDefault < effectiveMax ? narrowedDefault : effectiveMax;

  if (raw == null) {
    return SqlPage(limit: effectiveDefault, offset: 0);
  }
  if (raw is! Map<Object?, Object?>) {
    throw _graphqlValidationError(
      ctx,
      'graphql.page',
      'GraphQL page input must be an object.',
    );
  }

  final limit = (raw['limit'] as int?) ?? effectiveDefault;
  final offset = (raw['offset'] as int?) ?? 0;

  if (limit < 0 || offset < 0) {
    throw _graphqlValidationError(
      ctx,
      'graphql.page',
      'GraphQL page limit and offset must be non-negative.',
    );
  }

  if (limit > effectiveMax) {
    throw _graphqlValidationError(
      ctx,
      'graphql.page',
      'Requested page limit $limit exceeds the effective max limit $effectiveMax.',
    );
  }

  return SqlPage(limit: limit, offset: offset);
}

GraphQLError _graphqlValidationError(
  Ctx<Object?> ctx,
  String code,
  String message,
) {
  return GraphQLError(
    message,
    path: ctx.path,
    extensions: <String, Object?>{'code': code},
  );
}

GraphqlPublishedObject _objectById(GraphqlCatalog catalog, String objectId) {
  return catalog.objects.firstWhere(
    (object) => object.id == objectId,
    orElse: () => throw ArgumentError('Unknown catalog object $objectId.'),
  );
}

GraphqlCatalogField _fieldByPublicName(GraphqlPublishedObject object, String publicName) {
  return object.fields.firstWhere(
    (field) => field.publicName == publicName,
    orElse: () => throw ArgumentError('Unknown field $publicName for ${object.id}.'),
  );
}

GraphqlCatalogField _fieldByColumn(GraphqlPublishedObject object, String column) {
  return object.fields.firstWhere(
    (field) => field.column == column,
    orElse: () => throw ArgumentError('Unknown column $column for ${object.id}.'),
  );
}

int _extractTotalCount(RowSet rowSet) {
  if (rowSet.rows.isEmpty) {
    return 0;
  }
  final value = rowSet.rows.first['totalCount'];
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  throw StateError('Expected totalCount to be numeric, got $value.');
}

Map<String, Object?> _relationParentValues({
  required GraphqlPublishedObject sourceObject,
  required GraphqlCatalogRelation relation,
  required Map<Object?, Object?> parent,
}) {
  final values = <String, Object?>{};
  for (final column in relation.sourceFields) {
    final publicName = _fieldByColumn(sourceObject, column).publicName;
    values[publicName] = parent[publicName];
  }
  return values;
}

String _targetRowCacheKey({
  required GraphqlPublishedObject targetObject,
  required GraphqlCatalogRelation relation,
  required Map<String, Object?> row,
}) {
  final values = <Object?>[];
  for (final column in relation.targetFields) {
    final publicName = _fieldByColumn(targetObject, column).publicName;
    values.add(row[publicName]);
  }
  return jsonEncode(values);
}

final class _RelationParentKey {
  const _RelationParentKey({
    required this.sourceObjectId,
    required this.relationName,
    required this.values,
  });

  final String sourceObjectId;
  final String relationName;
  final Map<String, Object?> values;

  String get cacheKey => jsonEncode(values.values.toList(growable: false));
}