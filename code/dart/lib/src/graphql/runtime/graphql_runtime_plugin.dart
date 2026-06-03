import 'dart:convert';

import 'package:leto/leto.dart';
import 'package:leto_schema/utilities.dart' as leto_schema;
import 'package:leto_shelf/leto_shelf.dart';
import 'package:modular_api/src/core/plugin.dart';
import 'package:modular_api/src/graphql/catalog/graphql_catalog_builder.dart';
import 'package:modular_api/src/graphql/read/sql_read_contract.dart';
import 'package:modular_api/src/graphql/runtime/graphql_runtime_health.dart';
import 'package:modular_api/src/graphql/runtime/graphql_runtime_options.dart';
import 'package:shelf/shelf.dart';

const _graphQlPluginHostRange = '>=0.1.0 <0.2.0';

Future<Plugin> buildGraphqlRuntimePlugin({
  required GraphqlOptions options,
  required GraphqlRuntimeState runtimeState,
}) async {
  _validateGraphqlOptions(options);

  final catalog = await _buildCatalog(options);
  final graphQL = _buildGraphQlEngine(options, catalog);

  return _GraphqlRuntimePlugin(
    options: options,
    runtimeState: runtimeState,
    graphQL: graphQL,
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

GraphQL _buildGraphQlEngine(GraphqlOptions options, GraphqlCatalog catalog) {
  try {
    final sdl = options.sdlFactory(catalog);
    final schema = leto_schema.buildSchema(sdl);
    return GraphQL(
      schema,
      introspect: options.introspectionEnabled,
      validate: true,
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
    required this.graphQL,
  });

  final GraphqlOptions options;
  final GraphqlRuntimeState runtimeState;
  final GraphQL graphQL;

  SqlReadExecutor? _resolvedExecutor;
  String? _executorValidationMessage;
  String? _executorValidationResourceId;

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

    final handler = graphQLHttp(graphQL);

    host.registerRoute(
      PluginRoute(
        id: 'graphql.endpoint.get',
        method: 'GET',
        path: '/graphql',
        visibility: 'custom',
        handler: (context) => handler(_toShelfRequest(context)),
      ),
    );
    host.registerRoute(
      PluginRoute(
        id: 'graphql.endpoint.post',
        method: 'POST',
        path: '/graphql',
        visibility: 'custom',
        handler: (context) => handler(_toShelfRequest(context)),
      ),
    );

    if (_resolvedExecutor != null) {
      runtimeState.markReady();
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
  );
}