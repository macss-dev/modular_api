import 'package:json5/json5.dart';
import 'package:modular_api/src/graphql/sqlserver/physical_model.dart';

enum GraphqlMetadataSeverity {
  error,
  warning,
}

final class GraphqlMetadataDiagnostic {
  const GraphqlMetadataDiagnostic({
    required this.severity,
    required this.code,
    required this.message,
    this.objectId,
    this.field,
  });

  final GraphqlMetadataSeverity severity;
  final String code;
  final String message;
  final String? objectId;
  final String? field;
}

final class GraphqlMetadataLimit {
  const GraphqlMetadataLimit({
    required this.defaultValue,
    required this.maxValue,
  });

  final int defaultValue;
  final int maxValue;
}

final class GraphqlFieldMetadata {
  const GraphqlFieldMetadata({
    this.hidden = false,
    this.sensitive = false,
    this.noFilter = false,
    this.noSort = false,
    this.name,
  });

  final bool hidden;
  final bool sensitive;
  final bool noFilter;
  final bool noSort;
  final String? name;
}

final class GraphqlRelationMetadata {
  const GraphqlRelationMetadata({
    required this.name,
    required this.cardinality,
    required this.target,
    required this.via,
  });

  final String name;
  final String cardinality;
  final String target;
  final List<String> via;
}

final class GraphqlObjectMetadata {
  const GraphqlObjectMetadata({
    required this.publish,
    this.name,
    this.key,
    this.fields = const <String, GraphqlFieldMetadata>{},
    this.relations = const <GraphqlRelationMetadata>[],
    this.limit,
  });

  final bool publish;
  final String? name;
  final List<String>? key;
  final Map<String, GraphqlFieldMetadata> fields;
  final List<GraphqlRelationMetadata> relations;
  final GraphqlMetadataLimit? limit;
}

final class GraphqlMetadataFile {
  const GraphqlMetadataFile({
    required this.version,
    required this.objects,
    this.schema,
    this.defaultsLimit,
  });

  final String? schema;
  final int version;
  final GraphqlMetadataLimit? defaultsLimit;
  final Map<String, GraphqlObjectMetadata> objects;
}

final class GraphqlMetadataParseResult {
  const GraphqlMetadataParseResult({
    required this.metadata,
    required this.diagnostics,
  });

  final GraphqlMetadataFile? metadata;
  final List<GraphqlMetadataDiagnostic> diagnostics;
}

final class GraphqlMetadataParser {
  const GraphqlMetadataParser();

  GraphqlMetadataParseResult parse({
    required String rawJsonc,
    required PhysicalCatalog physicalCatalog,
  }) {
    final diagnostics = <GraphqlMetadataDiagnostic>[];
    final physicalObjectsById = <String, PhysicalObject>{
      for (final object in physicalCatalog.objects) object.id: object,
    };

    final Object? decoded;
    try {
      decoded = JSON5.parse(rawJsonc);
    } catch (error) {
      return GraphqlMetadataParseResult(
        metadata: null,
        diagnostics: <GraphqlMetadataDiagnostic>[
          GraphqlMetadataDiagnostic(
            severity: GraphqlMetadataSeverity.error,
            code: 'metadata_invalid_shape',
            message: 'Failed to parse graphql.metadata.jsonc: $error',
          ),
        ],
      );
    }

    if (decoded is! Map) {
      return GraphqlMetadataParseResult(
        metadata: null,
        diagnostics: <GraphqlMetadataDiagnostic>[
          const GraphqlMetadataDiagnostic(
            severity: GraphqlMetadataSeverity.error,
            code: 'metadata_invalid_shape',
            message: 'Top-level metadata value must be an object.',
          ),
        ],
      );
    }

    final root = Map<String, dynamic>.from(decoded);
    _collectUnknownKeys(
      map: root,
      allowedKeys: const <String>{'4schema', 'version', 'defaults', 'objects'},
      diagnostics: diagnostics,
    );

    final version = root['version'];
    if (version is! int || version != 1) {
      diagnostics.add(
        GraphqlMetadataDiagnostic(
          severity: GraphqlMetadataSeverity.error,
          code: 'metadata_invalid_shape',
          message: 'Metadata version must be the integer 1.',
          field: 'version',
        ),
      );
    }

    final objectsValue = root['objects'];
    if (objectsValue is! Map) {
      diagnostics.add(
        GraphqlMetadataDiagnostic(
          severity: GraphqlMetadataSeverity.error,
          code: 'metadata_invalid_shape',
          message: 'Metadata objects must be an object keyed by schema.object.',
          field: 'objects',
        ),
      );
      return GraphqlMetadataParseResult(
        metadata: null,
        diagnostics: _sortDiagnostics(diagnostics),
      );
    }

    final schema = root['4schema'];
    final defaultsLimit = _parseLimit(
      scopeName: 'defaults.limit',
      value: _readOptionalChildMap(root, 'defaults')?['limit'],
      diagnostics: diagnostics,
    );
    final objects = <String, GraphqlObjectMetadata>{};
    final objectIds = objectsValue.keys.map((key) => key.toString()).toList()..sort();

    for (final objectId in objectIds) {
      final objectValue = objectsValue[objectId];
      if (objectValue is! Map) {
        diagnostics.add(
          GraphqlMetadataDiagnostic(
            severity: GraphqlMetadataSeverity.error,
            code: 'metadata_invalid_shape',
            message: 'Metadata object entry must be an object.',
            objectId: objectId,
          ),
        );
        continue;
      }

      final objectMap = Map<String, dynamic>.from(objectValue);
      _collectUnknownKeys(
        map: objectMap,
        allowedKeys: const <String>{
          'publish',
          'name',
          'key',
          'fields',
          'relations',
          'limit',
        },
        diagnostics: diagnostics,
        objectId: objectId,
      );

      if (objectMap['publish'] != true) {
        diagnostics.add(
          GraphqlMetadataDiagnostic(
            severity: GraphqlMetadataSeverity.error,
            code: 'metadata_invalid_shape',
            message: 'Object metadata entry must declare publish: true.',
            objectId: objectId,
            field: 'publish',
          ),
        );
        continue;
      }

      final metadata = GraphqlObjectMetadata(
        publish: true,
        name: _readOptionalString(objectMap, 'name', diagnostics, objectId),
        key: _readOptionalStringList(objectMap, 'key', diagnostics, objectId),
        fields: _parseFields(objectMap['fields'], diagnostics, objectId),
        relations: _parseRelations(objectMap['relations'], diagnostics, objectId),
        limit: _parseLimit(
          scopeName: '$objectId.limit',
          value: objectMap['limit'],
          diagnostics: diagnostics,
          objectId: objectId,
        ),
      );
      objects[objectId] = metadata;

      final physicalObject = physicalObjectsById[objectId];
      if (physicalObject == null) {
        diagnostics.add(
          GraphqlMetadataDiagnostic(
            severity: GraphqlMetadataSeverity.error,
            code: 'metadata_object_unknown',
            message: 'Metadata references an object not present in the physical model.',
            objectId: objectId,
          ),
        );
        continue;
      }

      if (physicalObject.kind == PhysicalObjectKind.view &&
          (metadata.key == null || metadata.key!.isEmpty)) {
        diagnostics.add(
          GraphqlMetadataDiagnostic(
            severity: GraphqlMetadataSeverity.error,
            code: 'view_missing_identity',
            message: 'Published view requires explicit key metadata in v1.',
            objectId: objectId,
          ),
        );
      }
    }

    return GraphqlMetadataParseResult(
      metadata: GraphqlMetadataFile(
        schema: schema is String ? schema : null,
        version: version is int ? version : 0,
        defaultsLimit: defaultsLimit,
        objects: objects,
      ),
      diagnostics: _sortDiagnostics(diagnostics),
    );
  }
}

void _collectUnknownKeys({
  required Map<String, dynamic> map,
  required Set<String> allowedKeys,
  required List<GraphqlMetadataDiagnostic> diagnostics,
  String? objectId,
}) {
  final unknownKeys = map.keys.where((key) => !allowedKeys.contains(key)).toList()
    ..sort();

  for (final key in unknownKeys) {
    diagnostics.add(
      GraphqlMetadataDiagnostic(
        severity: GraphqlMetadataSeverity.warning,
        code: 'metadata_unknown_key',
        message: 'Unknown metadata key: $key',
        objectId: objectId,
        field: key,
      ),
    );
  }
}

Map<String, dynamic>? _readOptionalChildMap(Map<String, dynamic> parent, String key) {
  final value = parent[key];
  if (value == null) {
    return null;
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }

  return null;
}

String? _readOptionalString(
  Map<String, dynamic> map,
  String key,
  List<GraphqlMetadataDiagnostic> diagnostics,
  String? objectId,
) {
  final value = map[key];
  if (value == null) {
    return null;
  }
  if (value is String) {
    return value;
  }

  diagnostics.add(
    GraphqlMetadataDiagnostic(
      severity: GraphqlMetadataSeverity.error,
      code: 'metadata_invalid_shape',
      message: 'Metadata field must be a string.',
      objectId: objectId,
      field: key,
    ),
  );
  return null;
}

List<String>? _readOptionalStringList(
  Map<String, dynamic> map,
  String key,
  List<GraphqlMetadataDiagnostic> diagnostics,
  String? objectId,
) {
  final value = map[key];
  if (value == null) {
    return null;
  }
  if (value is! List) {
    diagnostics.add(
      GraphqlMetadataDiagnostic(
        severity: GraphqlMetadataSeverity.error,
        code: 'metadata_invalid_shape',
        message: 'Metadata field must be an array of strings.',
        objectId: objectId,
        field: key,
      ),
    );
    return null;
  }

  final result = <String>[];
  for (final item in value) {
    if (item is! String) {
      diagnostics.add(
        GraphqlMetadataDiagnostic(
          severity: GraphqlMetadataSeverity.error,
          code: 'metadata_invalid_shape',
          message: 'Metadata field must be an array of strings.',
          objectId: objectId,
          field: key,
        ),
      );
      return null;
    }
    result.add(item);
  }

  return List<String>.unmodifiable(result);
}

Map<String, GraphqlFieldMetadata> _parseFields(
  Object? value,
  List<GraphqlMetadataDiagnostic> diagnostics,
  String objectId,
) {
  if (value == null) {
    return const <String, GraphqlFieldMetadata>{};
  }
  if (value is! Map) {
    diagnostics.add(
      GraphqlMetadataDiagnostic(
        severity: GraphqlMetadataSeverity.error,
        code: 'metadata_invalid_shape',
        message: 'fields must be an object keyed by column name.',
        objectId: objectId,
        field: 'fields',
      ),
    );
    return const <String, GraphqlFieldMetadata>{};
  }

  final fieldKeys = value.keys.map((key) => key.toString()).toList()..sort();
  final fields = <String, GraphqlFieldMetadata>{};
  for (final fieldName in fieldKeys) {
    final fieldValue = value[fieldName];
    if (fieldValue is! Map) {
      diagnostics.add(
        GraphqlMetadataDiagnostic(
          severity: GraphqlMetadataSeverity.error,
          code: 'metadata_invalid_shape',
          message: 'Field metadata entry must be an object.',
          objectId: objectId,
          field: fieldName,
        ),
      );
      continue;
    }

    final fieldMap = Map<String, dynamic>.from(fieldValue);
    _collectUnknownKeys(
      map: fieldMap,
      allowedKeys: const <String>{'hidden', 'sensitive', 'noFilter', 'noSort', 'name'},
      diagnostics: diagnostics,
      objectId: objectId,
    );
    fields[fieldName] = GraphqlFieldMetadata(
      hidden: _readOptionalBool(fieldMap, 'hidden', diagnostics, objectId, fieldName),
      sensitive: _readOptionalBool(fieldMap, 'sensitive', diagnostics, objectId, fieldName),
      noFilter: _readOptionalBool(fieldMap, 'noFilter', diagnostics, objectId, fieldName),
      noSort: _readOptionalBool(fieldMap, 'noSort', diagnostics, objectId, fieldName),
      name: _readOptionalString(fieldMap, 'name', diagnostics, objectId),
    );
  }

  return Map<String, GraphqlFieldMetadata>.unmodifiable(fields);
}

List<GraphqlRelationMetadata> _parseRelations(
  Object? value,
  List<GraphqlMetadataDiagnostic> diagnostics,
  String objectId,
) {
  if (value == null) {
    return const <GraphqlRelationMetadata>[];
  }
  if (value is! List) {
    diagnostics.add(
      GraphqlMetadataDiagnostic(
        severity: GraphqlMetadataSeverity.error,
        code: 'metadata_invalid_shape',
        message: 'relations must be an array.',
        objectId: objectId,
        field: 'relations',
      ),
    );
    return const <GraphqlRelationMetadata>[];
  }

  final relations = <GraphqlRelationMetadata>[];
  for (final entry in value) {
    if (entry is! Map) {
      diagnostics.add(
        GraphqlMetadataDiagnostic(
          severity: GraphqlMetadataSeverity.error,
          code: 'metadata_invalid_shape',
          message: 'Relation entry must be an object.',
          objectId: objectId,
          field: 'relations',
        ),
      );
      continue;
    }
    final relation = Map<String, dynamic>.from(entry);
    relations.add(
      GraphqlRelationMetadata(
        name: relation['name']?.toString() ?? '',
        cardinality: relation['cardinality']?.toString() ?? '',
        target: relation['target']?.toString() ?? '',
        via: relation['via'] is List
            ? List<String>.unmodifiable(
                (relation['via'] as List).map((item) => item.toString()),
              )
            : const <String>[],
      ),
    );
  }

  return List<GraphqlRelationMetadata>.unmodifiable(relations);
}

GraphqlMetadataLimit? _parseLimit({
  required String scopeName,
  required Object? value,
  required List<GraphqlMetadataDiagnostic> diagnostics,
  String? objectId,
}) {
  if (value == null) {
    return null;
  }
  if (value is! Map) {
    diagnostics.add(
      GraphqlMetadataDiagnostic(
        severity: GraphqlMetadataSeverity.error,
        code: 'metadata_invalid_shape',
        message: 'Limit metadata must be an object.',
        objectId: objectId,
        field: scopeName,
      ),
    );
    return null;
  }

  final limitMap = Map<String, dynamic>.from(value);
  final defaultValue = limitMap['default'];
  final maxValue = limitMap['max'];
  if (defaultValue is! int || maxValue is! int) {
    diagnostics.add(
      GraphqlMetadataDiagnostic(
        severity: GraphqlMetadataSeverity.error,
        code: 'metadata_invalid_shape',
        message: 'Limit metadata requires integer default and max values.',
        objectId: objectId,
        field: scopeName,
      ),
    );
    return null;
  }
  if (defaultValue > maxValue) {
    diagnostics.add(
      GraphqlMetadataDiagnostic(
        severity: GraphqlMetadataSeverity.error,
        code: 'metadata_invalid_shape',
        message: 'Limit metadata requires default <= max.',
        objectId: objectId,
        field: scopeName,
      ),
    );
  }

  return GraphqlMetadataLimit(
    defaultValue: defaultValue,
    maxValue: maxValue,
  );
}

bool _readOptionalBool(
  Map<String, dynamic> map,
  String key,
  List<GraphqlMetadataDiagnostic> diagnostics,
  String? objectId,
  String? field,
) {
  final value = map[key];
  if (value == null) {
    return false;
  }
  if (value is bool) {
    return value;
  }

  diagnostics.add(
    GraphqlMetadataDiagnostic(
      severity: GraphqlMetadataSeverity.error,
      code: 'metadata_invalid_shape',
      message: 'Metadata flag must be a boolean.',
      objectId: objectId,
      field: field ?? key,
    ),
  );
  return false;
}

List<GraphqlMetadataDiagnostic> _sortDiagnostics(
  List<GraphqlMetadataDiagnostic> diagnostics,
) {
  final sorted = diagnostics.toList()
    ..sort((left, right) {
      final severityOrder = left.severity.index.compareTo(right.severity.index);
      if (severityOrder != 0) {
        return severityOrder;
      }

      final codeOrder = left.code.compareTo(right.code);
      if (codeOrder != 0) {
        return codeOrder;
      }

      final objectOrder = (left.objectId ?? '').compareTo(right.objectId ?? '');
      if (objectOrder != 0) {
        return objectOrder;
      }

      final fieldOrder = (left.field ?? '').compareTo(right.field ?? '');
      if (fieldOrder != 0) {
        return fieldOrder;
      }

      return left.message.compareTo(right.message);
    });

  return List<GraphqlMetadataDiagnostic>.unmodifiable(sorted);
}