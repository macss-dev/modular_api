import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:modular_api/src/graphql/catalog/graphql_catalog_builder.dart';
import 'package:modular_api/src/graphql/runtime/graphql_runtime_options.dart';
import 'package:modular_api/src/graphql/schema/graphql_schema_sdl_generator.dart';
import 'package:modular_api/src/graphql/sqlserver/physical_model.dart';

const _catalogFileName = 'catalog.json';
const _catalogLockFileName = 'catalog.lock';
const _diagnosticsFileName = 'diagnostics.json';
const _schemaFileName = 'schema.graphql';

final class GraphqlArtifactBundle {
  const GraphqlArtifactBundle({
    required this.catalogJson,
    required this.catalogLockJson,
    required this.diagnosticsJson,
    required this.schemaGraphql,
  });

  final String catalogJson;
  final String catalogLockJson;
  final String diagnosticsJson;
  final String schemaGraphql;

  Future<void> writeToDirectory(String outputDirectory) async {
    final directory = Directory(outputDirectory);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    await File(_artifactPath(outputDirectory, _catalogFileName)).writeAsString(catalogJson);
    await File(_artifactPath(outputDirectory, _catalogLockFileName)).writeAsString(catalogLockJson);
    await File(_artifactPath(outputDirectory, _diagnosticsFileName)).writeAsString(diagnosticsJson);
    await File(_artifactPath(outputDirectory, _schemaFileName)).writeAsString(schemaGraphql);
  }
}

final class GraphqlArtifactCompileError implements Exception {
  const GraphqlArtifactCompileError({
    required this.message,
    required this.bundle,
  });

  final String message;
  final GraphqlArtifactBundle bundle;

  @override
  String toString() => 'GraphqlArtifactCompileError($message)';
}

final class GraphqlArtifactCompiler {
  GraphqlArtifactCompiler({
    required this.catalogFactory,
    GraphqlSdlFactory? sdlFactory,
  }) : sdlFactory = sdlFactory ?? const GraphqlSchemaSdlGenerator().generate;

  final GraphqlCatalogFactory catalogFactory;
  final GraphqlSdlFactory sdlFactory;

  Future<GraphqlArtifactBundle> compile() async {
    final rawCatalog = await Future<GraphqlCatalog>.sync(catalogFactory);
    final catalog = _canonicalCatalog(rawCatalog);
    final bundle = GraphqlArtifactBundle(
      catalogJson: _prettyJson(_catalogToJson(catalog)),
      catalogLockJson: _prettyJson(_catalogLockToJson(catalog)),
      diagnosticsJson: _prettyJson(_diagnosticsToJson(catalog.diagnostics)),
      schemaGraphql: _normalizedSchema(sdlFactory(catalog)),
    );

    final blockingDiagnostics = catalog.diagnostics
        .where((diagnostic) =>
            diagnostic.severity == GraphqlCatalogDiagnosticSeverity.error)
        .toList(growable: false);
    if (blockingDiagnostics.isNotEmpty) {
      throw GraphqlArtifactCompileError(
        message: 'GraphQL artifact compilation failed because blocking diagnostics exist.',
        bundle: bundle,
      );
    }

    return bundle;
  }

  Future<GraphqlArtifactBundle> writeToDirectory(String outputDirectory) async {
    try {
      final bundle = await compile();
      await bundle.writeToDirectory(outputDirectory);
      return bundle;
    } on GraphqlArtifactCompileError catch (error) {
      await error.bundle.writeToDirectory(outputDirectory);
      rethrow;
    }
  }
}

Future<GraphqlCatalog?> tryLoadGraphqlCatalogArtifacts({
  required String artifactDirectory,
  required String currentSourceDigest,
}) async {
  final catalogFile = File(_artifactPath(artifactDirectory, _catalogFileName));
  final lockFile = File(_artifactPath(artifactDirectory, _catalogLockFileName));
  if (!await catalogFile.exists() || !await lockFile.exists()) {
    return null;
  }

  final lockJson = jsonDecode(await lockFile.readAsString());
  if (lockJson is! Map<String, Object?>) {
    throw const FormatException('catalog.lock must be a JSON object.');
  }
  final lock = _catalogLockFromJson(lockJson);
  if (lock.sourceDigest != currentSourceDigest) {
    return null;
  }

  final catalogJson = jsonDecode(await catalogFile.readAsString());
  if (catalogJson is! Map<String, Object?>) {
    throw const FormatException('catalog.json must be a JSON object.');
  }
  final catalog = _canonicalCatalog(_catalogFromJson(catalogJson));
  if (catalog.catalogVersion != lock.catalogVersion ||
      catalog.build.sourceDigest != lock.sourceDigest ||
      catalog.provider.providerVersion != lock.providerVersion) {
    return null;
  }

  return catalog;
}

String _artifactPath(String directory, String fileName) {
  return '$directory${Platform.pathSeparator}$fileName';
}

String _prettyJson(Object? payload) {
  return '${const JsonEncoder.withIndent('  ').convert(_canonicalize(payload))}\n';
}

String _normalizedSchema(String schema) {
  final normalized = schema.endsWith('\n') ? schema : '$schema\n';
  return normalized;
}

GraphqlCatalog _canonicalCatalog(GraphqlCatalog catalog) {
  final objects = catalog.objects
      .map(_canonicalObject)
      .toList(growable: false)
    ..sort((left, right) => left.id.compareTo(right.id));
  final diagnostics = List<GraphqlCatalogDiagnostic>.of(catalog.diagnostics)
    ..sort(_compareDiagnostics);

  return GraphqlCatalog(
    catalogVersion: catalog.catalogVersion,
    provider: catalog.provider,
    build: catalog.build,
    objects: List<GraphqlPublishedObject>.unmodifiable(objects),
    diagnostics: List<GraphqlCatalogDiagnostic>.unmodifiable(diagnostics),
  );
}

GraphqlPublishedObject _canonicalObject(GraphqlPublishedObject object) {
  final fields = List<GraphqlCatalogField>.of(object.fields)
    ..sort((left, right) {
      final publicName = left.publicName.compareTo(right.publicName);
      if (publicName != 0) {
        return publicName;
      }
      return left.column.compareTo(right.column);
    });
  final relations = List<GraphqlCatalogRelation>.of(object.relations)
    ..sort((left, right) {
      final name = left.name.compareTo(right.name);
      if (name != 0) {
        return name;
      }
      return left.target.compareTo(right.target);
    });

  return GraphqlPublishedObject(
    id: object.id,
    kind: object.kind,
    readonly: object.readonly,
    source: object.source,
    graphql: object.graphql,
    identity: object.identity,
    fields: List<GraphqlCatalogField>.unmodifiable(fields),
    relations: List<GraphqlCatalogRelation>.unmodifiable(relations),
    capabilities: object.capabilities,
  );
}

int _compareDiagnostics(
  GraphqlCatalogDiagnostic left,
  GraphqlCatalogDiagnostic right,
) {
  final severity = left.severity.index.compareTo(right.severity.index);
  if (severity != 0) {
    return severity;
  }
  final code = left.code.compareTo(right.code);
  if (code != 0) {
    return code;
  }
  final objectId = (left.objectId ?? '').compareTo(right.objectId ?? '');
  if (objectId != 0) {
    return objectId;
  }
  final field = (left.field ?? '').compareTo(right.field ?? '');
  if (field != 0) {
    return field;
  }
  return left.message.compareTo(right.message);
}

Map<String, Object?> _catalogToJson(GraphqlCatalog catalog) {
  return <String, Object?>{
    'catalogVersion': catalog.catalogVersion,
    'provider': <String, Object?>{
      'kind': catalog.provider.kind,
      'engine': catalog.provider.engine,
      'providerVersion': catalog.provider.providerVersion,
    },
    'build': <String, Object?>{
      'mode': _buildModeValue(catalog.build.mode),
      'sourceRoot': catalog.build.sourceRoot,
      'sourceDigest': catalog.build.sourceDigest,
    },
    'objects': catalog.objects.map(_objectToJson).toList(growable: false),
    'diagnostics': _diagnosticsToJson(catalog.diagnostics),
  };
}

Map<String, Object?> _catalogLockToJson(GraphqlCatalog catalog) {
  return <String, Object?>{
    'catalogVersion': catalog.catalogVersion,
    'sourceDigest': catalog.build.sourceDigest,
    'providerVersion': catalog.provider.providerVersion,
  };
}

List<Object?> _diagnosticsToJson(Iterable<GraphqlCatalogDiagnostic> diagnostics) {
  return diagnostics.map((diagnostic) {
    return <String, Object?>{
      'severity': _diagnosticSeverityValue(diagnostic.severity),
      'code': diagnostic.code,
      'message': diagnostic.message,
      'objectId': diagnostic.objectId,
      'field': diagnostic.field,
    };
  }).toList(growable: false);
}

Map<String, Object?> _objectToJson(GraphqlPublishedObject object) {
  return <String, Object?>{
    'id': object.id,
    'kind': _kindValue(object.kind),
    'readonly': object.readonly,
    'source': <String, Object?>{
      'schemaName': object.source.schemaName,
      'objectName': object.source.objectName,
      'sourceFile': object.source.sourceFile,
      'providerObjectId': object.source.providerObjectId,
    },
    'graphql': <String, Object?>{
      'typeName': object.graphql.typeName,
      'collectionField': object.graphql.collectionField,
      'itemField': object.graphql.itemField,
    },
    'identity': <String, Object?>{
      'mode': _identityModeValue(object.identity.mode),
      'fields': object.identity.fields,
      'origin': _originValue(object.identity.origin),
    },
    'fields': object.fields.map((field) {
      return <String, Object?>{
        'column': field.column,
        'publicName': field.publicName,
        'type': field.type,
        'nullable': field.nullable,
        'visibility': _fieldVisibilityValue(field.visibility),
        'filterable': field.filterable,
        'sortable': field.sortable,
        'sensitive': field.sensitive,
        'origin': _originValue(field.origin),
      };
    }).toList(growable: false),
    'relations': object.relations.map((relation) {
      return <String, Object?>{
        'name': relation.name,
        'target': relation.target,
        'cardinality': _relationCardinalityValue(relation.cardinality),
        'sourceFields': relation.sourceFields,
        'targetFields': relation.targetFields,
        'origin': _originValue(relation.origin),
      };
    }).toList(growable: false),
    'capabilities': <String, Object?>{
      'item': object.capabilities.item,
      'collection': object.capabilities.collection,
      'filter': object.capabilities.filter,
      'sort': object.capabilities.sort,
      'pagination': <String, Object?>{
        'mode': _paginationModeValue(object.capabilities.pagination.mode),
        'defaultLimit': object.capabilities.pagination.defaultLimit,
        'maxLimit': object.capabilities.pagination.maxLimit,
      },
    },
  };
}

GraphqlCatalog _catalogFromJson(Map<String, Object?> json) {
  final providerJson = json['provider'] as Map<String, Object?>;
  final buildJson = json['build'] as Map<String, Object?>;
  final objectsJson = (json['objects'] as List<Object?>?) ?? const <Object?>[];
  final diagnosticsJson =
      (json['diagnostics'] as List<Object?>?) ?? const <Object?>[];

  return GraphqlCatalog(
    catalogVersion: json['catalogVersion'] as String,
    provider: GraphqlCatalogProvider(
      kind: providerJson['kind'] as String,
      engine: providerJson['engine'] as String,
      providerVersion: providerJson['providerVersion'] as String,
    ),
    build: GraphqlCatalogBuild(
      mode: _buildModeFromJson(buildJson['mode'] as String),
      sourceRoot: buildJson['sourceRoot'] as String,
      sourceDigest: buildJson['sourceDigest'] as String,
    ),
    objects: objectsJson
        .whereType<Map<String, Object?>>()
        .map(_objectFromJson)
        .toList(growable: false),
    diagnostics: diagnosticsJson
        .whereType<Map<String, Object?>>()
        .map(_diagnosticFromJson)
        .toList(growable: false),
  );
}

_CatalogLock _catalogLockFromJson(Map<String, Object?> json) {
  return _CatalogLock(
    catalogVersion: json['catalogVersion'] as String,
    sourceDigest: json['sourceDigest'] as String,
    providerVersion: json['providerVersion'] as String,
  );
}

GraphqlPublishedObject _objectFromJson(Map<String, Object?> json) {
  final sourceJson = json['source'] as Map<String, Object?>;
  final graphqlJson = json['graphql'] as Map<String, Object?>;
  final identityJson = json['identity'] as Map<String, Object?>;
  final capabilitiesJson = json['capabilities'] as Map<String, Object?>;
  final paginationJson = capabilitiesJson['pagination'] as Map<String, Object?>;

  return GraphqlPublishedObject(
    id: json['id'] as String,
    kind: _kindFromJson(json['kind'] as String),
    readonly: json['readonly'] as bool,
    source: GraphqlCatalogSource(
      schemaName: sourceJson['schemaName'] as String,
      objectName: sourceJson['objectName'] as String,
      sourceFile: sourceJson['sourceFile'] as String?,
      providerObjectId: sourceJson['providerObjectId'] as String?,
    ),
    graphql: GraphqlCatalogGraphqlNames(
      typeName: graphqlJson['typeName'] as String,
      collectionField: graphqlJson['collectionField'] as String,
      itemField: graphqlJson['itemField'] as String?,
    ),
    identity: GraphqlCatalogIdentity(
      mode: _identityModeFromJson(identityJson['mode'] as String),
      fields: (identityJson['fields'] as List<Object?>).cast<String>(),
      origin: _originFromJson(identityJson['origin'] as String),
    ),
    fields: ((json['fields'] as List<Object?>?) ?? const <Object?>[])
        .whereType<Map<String, Object?>>()
        .map((fieldJson) => GraphqlCatalogField(
              column: fieldJson['column'] as String,
              publicName: fieldJson['publicName'] as String,
              type: fieldJson['type'] as String,
              nullable: fieldJson['nullable'] as bool,
              visibility: _fieldVisibilityFromJson(fieldJson['visibility'] as String),
              filterable: fieldJson['filterable'] as bool,
              sortable: fieldJson['sortable'] as bool,
              sensitive: fieldJson['sensitive'] as bool,
              origin: _originFromJson(fieldJson['origin'] as String),
            ))
        .toList(growable: false),
    relations: ((json['relations'] as List<Object?>?) ?? const <Object?>[])
        .whereType<Map<String, Object?>>()
        .map((relationJson) => GraphqlCatalogRelation(
              name: relationJson['name'] as String,
              target: relationJson['target'] as String,
              cardinality: _relationCardinalityFromJson(
                relationJson['cardinality'] as String,
              ),
              sourceFields: (relationJson['sourceFields'] as List<Object?>).cast<String>(),
              targetFields: (relationJson['targetFields'] as List<Object?>).cast<String>(),
              origin: _originFromJson(relationJson['origin'] as String),
            ))
        .toList(growable: false),
    capabilities: GraphqlCatalogCapabilities(
      item: capabilitiesJson['item'] as bool,
      collection: capabilitiesJson['collection'] as bool,
      filter: capabilitiesJson['filter'] as bool,
      sort: capabilitiesJson['sort'] as bool,
      pagination: GraphqlCatalogPagination(
        mode: _paginationModeFromJson(paginationJson['mode'] as String),
        defaultLimit: paginationJson['defaultLimit'] as int,
        maxLimit: paginationJson['maxLimit'] as int,
      ),
    ),
  );
}

GraphqlCatalogDiagnostic _diagnosticFromJson(Map<String, Object?> json) {
  return GraphqlCatalogDiagnostic(
    severity: _diagnosticSeverityFromJson(json['severity'] as String),
    code: json['code'] as String,
    message: json['message'] as String,
    objectId: json['objectId'] as String?,
    field: json['field'] as String?,
  );
}

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList(growable: false)
      ..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalize(value[key]),
    };
  }
  if (value is List) {
    return value.map(_canonicalize).toList(growable: false);
  }
  return value;
}

String _buildModeValue(GraphqlCatalogBuildMode value) {
  switch (value) {
    case GraphqlCatalogBuildMode.compile:
      return 'compile';
    case GraphqlCatalogBuildMode.runtime:
      return 'runtime';
  }
}

GraphqlCatalogBuildMode _buildModeFromJson(String value) {
  switch (value) {
    case 'compile':
      return GraphqlCatalogBuildMode.compile;
    case 'runtime':
      return GraphqlCatalogBuildMode.runtime;
    default:
      throw ArgumentError('Unknown build mode $value.');
  }
}

String _kindValue(PhysicalObjectKind value) {
  switch (value) {
    case PhysicalObjectKind.table:
      return 'table';
    case PhysicalObjectKind.view:
      return 'view';
  }
}

PhysicalObjectKind _kindFromJson(String value) {
  switch (value) {
    case 'table':
      return PhysicalObjectKind.table;
    case 'view':
      return PhysicalObjectKind.view;
    default:
      throw ArgumentError('Unknown object kind $value.');
  }
}

String _identityModeValue(GraphqlCatalogIdentityMode value) {
  switch (value) {
    case GraphqlCatalogIdentityMode.single:
      return 'single';
    case GraphqlCatalogIdentityMode.composite:
      return 'composite';
    case GraphqlCatalogIdentityMode.none:
      return 'none';
  }
}

GraphqlCatalogIdentityMode _identityModeFromJson(String value) {
  switch (value) {
    case 'single':
      return GraphqlCatalogIdentityMode.single;
    case 'composite':
      return GraphqlCatalogIdentityMode.composite;
    case 'none':
      return GraphqlCatalogIdentityMode.none;
    default:
      throw ArgumentError('Unknown identity mode $value.');
  }
}

String _originValue(GraphqlCatalogOrigin value) {
  switch (value) {
    case GraphqlCatalogOrigin.inferred:
      return 'inferred';
    case GraphqlCatalogOrigin.annotated:
      return 'annotated';
  }
}

GraphqlCatalogOrigin _originFromJson(String value) {
  switch (value) {
    case 'inferred':
      return GraphqlCatalogOrigin.inferred;
    case 'annotated':
      return GraphqlCatalogOrigin.annotated;
    default:
      throw ArgumentError('Unknown catalog origin $value.');
  }
}

String _fieldVisibilityValue(GraphqlCatalogFieldVisibility value) {
  switch (value) {
    case GraphqlCatalogFieldVisibility.public:
      return 'public';
    case GraphqlCatalogFieldVisibility.hidden:
      return 'hidden';
  }
}

GraphqlCatalogFieldVisibility _fieldVisibilityFromJson(String value) {
  switch (value) {
    case 'public':
      return GraphqlCatalogFieldVisibility.public;
    case 'hidden':
      return GraphqlCatalogFieldVisibility.hidden;
    default:
      throw ArgumentError('Unknown field visibility $value.');
  }
}

String _relationCardinalityValue(GraphqlCatalogRelationCardinality value) {
  switch (value) {
    case GraphqlCatalogRelationCardinality.one:
      return 'one';
    case GraphqlCatalogRelationCardinality.many:
      return 'many';
  }
}

GraphqlCatalogRelationCardinality _relationCardinalityFromJson(String value) {
  switch (value) {
    case 'one':
      return GraphqlCatalogRelationCardinality.one;
    case 'many':
      return GraphqlCatalogRelationCardinality.many;
    default:
      throw ArgumentError('Unknown relation cardinality $value.');
  }
}

String _paginationModeValue(GraphqlCatalogPaginationMode value) {
  switch (value) {
    case GraphqlCatalogPaginationMode.offset:
      return 'offset';
    case GraphqlCatalogPaginationMode.none:
      return 'none';
  }
}

GraphqlCatalogPaginationMode _paginationModeFromJson(String value) {
  switch (value) {
    case 'offset':
      return GraphqlCatalogPaginationMode.offset;
    case 'none':
      return GraphqlCatalogPaginationMode.none;
    default:
      throw ArgumentError('Unknown pagination mode $value.');
  }
}

String _diagnosticSeverityValue(GraphqlCatalogDiagnosticSeverity value) {
  switch (value) {
    case GraphqlCatalogDiagnosticSeverity.error:
      return 'error';
    case GraphqlCatalogDiagnosticSeverity.warning:
      return 'warning';
    case GraphqlCatalogDiagnosticSeverity.info:
      return 'info';
  }
}

GraphqlCatalogDiagnosticSeverity _diagnosticSeverityFromJson(String value) {
  switch (value) {
    case 'error':
      return GraphqlCatalogDiagnosticSeverity.error;
    case 'warning':
      return GraphqlCatalogDiagnosticSeverity.warning;
    case 'info':
      return GraphqlCatalogDiagnosticSeverity.info;
    default:
      throw ArgumentError('Unknown diagnostic severity $value.');
  }
}

final class _CatalogLock {
  const _CatalogLock({
    required this.catalogVersion,
    required this.sourceDigest,
    required this.providerVersion,
  });

  final String catalogVersion;
  final String sourceDigest;
  final String providerVersion;
}