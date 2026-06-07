import 'package:dart_odbc/dart_odbc.dart';
import 'package:modular_api/modular_api.dart'
    show
        PhysicalCatalog,
        PhysicalField,
        PhysicalObject,
        PhysicalObjectKind,
        PhysicalRelationSeed;

import 'sql_server_connection_settings.dart';

typedef SqlServerOdbcFactory = IDartOdbc Function();

final class SqlServerMetadataReader {
  const SqlServerMetadataReader({
    required this.connection,
    SqlServerOdbcFactory? odbcFactory,
  }) : _odbcFactory = odbcFactory;

  final SqlServerConnectionSettings connection;
  final SqlServerOdbcFactory? _odbcFactory;

  Future<PhysicalCatalog> introspect({Set<String>? schemaNames}) async {
    final normalizedSchemaNames = schemaNames == null
        ? <String>[]
        : (schemaNames.toList()..sort());
    final objectsById = await _loadObjects(
      connection,
      _odbcFactory,
      normalizedSchemaNames,
    );

    await _loadFields(
      connection,
      _odbcFactory,
      normalizedSchemaNames,
      objectsById,
    );
    await _loadIdentityFields(
      connection,
      _odbcFactory,
      normalizedSchemaNames,
      objectsById,
    );
    await _loadRelations(
      connection,
      _odbcFactory,
      normalizedSchemaNames,
      objectsById,
    );

    final objects = objectsById.values.map((object) => object.build()).toList()
      ..sort((left, right) => left.id.compareTo(right.id));

    return PhysicalCatalog(objects: objects);
  }
}

IDartOdbc _defaultOdbcFactory() {
  return DartOdbc();
}

Future<Map<String, _PhysicalObjectAccumulator>> _loadObjects(
  SqlServerConnectionSettings connection,
  SqlServerOdbcFactory? odbcFactory,
  List<String> schemaNames,
) async {
  final rows = await _sendMetadataQuery(
    connection,
    odbcFactory,
    label: 'SQL Server objects',
    query: '''
SELECT
  s.name AS schema_name,
  o.name AS object_name,
  CASE o.type
    WHEN 'U' THEN 'table'
    WHEN 'V' THEN 'view'
  END AS object_kind
FROM sys.objects AS o
INNER JOIN sys.schemas AS s
  ON s.schema_id = o.schema_id
WHERE o.type IN ('U', 'V')${_schemaFilterClause('s.name', schemaNames)}
ORDER BY s.name, o.name;
''',
  );

  final objectsById = <String, _PhysicalObjectAccumulator>{};

  for (final row in rows) {
    final schemaName = _readString(row, 'schema_name');
    final objectName = _readString(row, 'object_name');
    final objectId = '$schemaName.$objectName';
    objectsById[objectId] = _PhysicalObjectAccumulator(
      id: objectId,
      kind: _parseObjectKind(_readString(row, 'object_kind')),
      schemaName: schemaName,
      objectName: objectName,
    );
  }

  return objectsById;
}

Future<void> _loadFields(
  SqlServerConnectionSettings connection,
  SqlServerOdbcFactory? odbcFactory,
  List<String> schemaNames,
  Map<String, _PhysicalObjectAccumulator> objectsById,
) async {
  final rows = await _sendMetadataQuery(
    connection,
    odbcFactory,
    label: 'SQL Server columns',
    query: '''
SELECT
  s.name AS schema_name,
  o.name AS object_name,
  c.name AS column_name,
  TYPE_NAME(c.user_type_id) AS type_name,
  CAST(c.max_length AS INT) AS max_length,
  CAST(c.precision AS INT) AS precision,
  CAST(c.scale AS INT) AS scale,
  CAST(c.is_nullable AS INT) AS is_nullable
FROM sys.objects AS o
INNER JOIN sys.schemas AS s
  ON s.schema_id = o.schema_id
INNER JOIN sys.columns AS c
  ON c.object_id = o.object_id
WHERE o.type IN ('U', 'V')${_schemaFilterClause('s.name', schemaNames)}
ORDER BY s.name, o.name, c.column_id;
''',
  );

  for (final row in rows) {
    final object = _requireObject(objectsById, row);
    object.fields.add(
      PhysicalField(
        column: _readString(row, 'column_name'),
        nativeType: _formatNativeType(
          typeName: _readString(row, 'type_name'),
          maxLength: _readInt(row, 'max_length'),
          precision: _readInt(row, 'precision'),
          scale: _readInt(row, 'scale'),
        ),
        nullable: _readBool(row, 'is_nullable'),
      ),
    );
  }
}

Future<void> _loadIdentityFields(
  SqlServerConnectionSettings connection,
  SqlServerOdbcFactory? odbcFactory,
  List<String> schemaNames,
  Map<String, _PhysicalObjectAccumulator> objectsById,
) async {
  final rows = await _sendMetadataQuery(
    connection,
    odbcFactory,
    label: 'SQL Server identity fields',
    query: '''
SELECT
  s.name AS schema_name,
  o.name AS object_name,
  c.name AS column_name
FROM sys.objects AS o
INNER JOIN sys.schemas AS s
  ON s.schema_id = o.schema_id
INNER JOIN sys.key_constraints AS kc
  ON kc.parent_object_id = o.object_id
 AND kc.type = 'PK'
INNER JOIN sys.index_columns AS ic
  ON ic.object_id = kc.parent_object_id
 AND ic.index_id = kc.unique_index_id
INNER JOIN sys.columns AS c
  ON c.object_id = ic.object_id
 AND c.column_id = ic.column_id
WHERE o.type = 'U'${_schemaFilterClause('s.name', schemaNames)}
ORDER BY s.name, o.name, ic.key_ordinal;
''',
  );

  for (final row in rows) {
    final object = _requireObject(objectsById, row);
    object.identityFields.add(_readString(row, 'column_name'));
  }
}

Future<void> _loadRelations(
  SqlServerConnectionSettings connection,
  SqlServerOdbcFactory? odbcFactory,
  List<String> schemaNames,
  Map<String, _PhysicalObjectAccumulator> objectsById,
) async {
  final rows = await _sendMetadataQuery(
    connection,
    odbcFactory,
    label: 'SQL Server foreign keys',
    query: '''
SELECT
  source_schema.name AS source_schema_name,
  source_object.name AS source_object_name,
  fk.name AS constraint_name,
  source_column.name AS source_column_name,
  target_schema.name AS target_schema_name,
  target_object.name AS target_object_name,
  target_column.name AS target_column_name
FROM sys.foreign_keys AS fk
INNER JOIN sys.foreign_key_columns AS fkc
  ON fkc.constraint_object_id = fk.object_id
INNER JOIN sys.objects AS source_object
  ON source_object.object_id = fk.parent_object_id
INNER JOIN sys.schemas AS source_schema
  ON source_schema.schema_id = source_object.schema_id
INNER JOIN sys.columns AS source_column
  ON source_column.object_id = source_object.object_id
 AND source_column.column_id = fkc.parent_column_id
INNER JOIN sys.objects AS target_object
  ON target_object.object_id = fk.referenced_object_id
INNER JOIN sys.schemas AS target_schema
  ON target_schema.schema_id = target_object.schema_id
INNER JOIN sys.columns AS target_column
  ON target_column.object_id = target_object.object_id
 AND target_column.column_id = fkc.referenced_column_id
WHERE source_object.type = 'U'${_schemaFilterClause('source_schema.name', schemaNames)}
ORDER BY source_schema.name, source_object.name, fk.name, fkc.constraint_column_id;
''',
  );
  final relationsByKey = <String, _RelationAccumulator>{};

  for (final row in rows) {
    final sourceSchemaName = _readString(row, 'source_schema_name');
    final sourceObjectName = _readString(row, 'source_object_name');
    final targetSchemaName = _readString(row, 'target_schema_name');
    final targetObjectName = _readString(row, 'target_object_name');
    final constraintName = _readString(row, 'constraint_name');

    final sourceObjectId = '$sourceSchemaName.$sourceObjectName';
    final targetObjectId = '$targetSchemaName.$targetObjectName';
    final relationKey = '$sourceObjectId|$constraintName|$targetObjectId';
    final relation = relationsByKey.putIfAbsent(
      relationKey,
      () => _RelationAccumulator(
        name: constraintName,
        sourceObjectId: sourceObjectId,
        targetObjectId: targetObjectId,
      ),
    );

    relation.sourceFields.add(_readString(row, 'source_column_name'));
    relation.targetFields.add(_readString(row, 'target_column_name'));
  }

  for (final relation in relationsByKey.values) {
    final sourceObject = objectsById[relation.sourceObjectId];
    if (sourceObject == null) {
      throw StateError(
        'Missing source object for relation ${relation.name}: ${relation.sourceObjectId}',
      );
    }

    sourceObject.relations.add(
      PhysicalRelationSeed(
        name: relation.name,
        sourceObjectId: relation.sourceObjectId,
        targetObjectId: relation.targetObjectId,
        sourceFields: List<String>.unmodifiable(relation.sourceFields),
        targetFields: List<String>.unmodifiable(relation.targetFields),
      ),
    );
  }
}

Future<List<Map<String, dynamic>>> _sendMetadataQuery(
  SqlServerConnectionSettings connection,
  SqlServerOdbcFactory? odbcFactory, {
  required String label,
  required String query,
}) async {
  final odbc = (odbcFactory ?? _defaultOdbcFactory)();
  try {
    await odbc.connectWithConnectionString(_buildConnectionString(connection));
    return await odbc.execute(query);
  } on ODBCException catch (error) {
    throw StateError('Failed to load $label: $error');
  } finally {
    try {
      await odbc.disconnect();
    } catch (_) {}
  }
}

String _buildConnectionString(SqlServerConnectionSettings connection) {
  final parts = <String>[
    'DRIVER={${connection.driver}}',
    'SERVER=${connection.host},${connection.port}',
    'DATABASE=${connection.database}',
    'UID=${connection.username}',
    'PWD=${connection.password}',
    'Encrypt=no',
    'TrustServerCertificate=yes',
  ];

  return '${parts.join(';')};';
}

_PhysicalObjectAccumulator _requireObject(
  Map<String, _PhysicalObjectAccumulator> objectsById,
  Map<String, dynamic> row,
) {
  final schemaName = _readString(row, 'schema_name');
  final objectName = _readString(row, 'object_name');
  final objectId = '$schemaName.$objectName';
  final object = objectsById[objectId];
  if (object == null) {
    throw StateError('Object not loaded before metadata expansion: $objectId');
  }

  return object;
}

PhysicalObjectKind _parseObjectKind(String value) {
  switch (value) {
    case 'table':
      return PhysicalObjectKind.table;
    case 'view':
      return PhysicalObjectKind.view;
    default:
      throw StateError('Unsupported SQL Server object kind: $value');
  }
}

String _schemaFilterClause(String column, List<String> schemaNames) {
  if (schemaNames.isEmpty) {
    return '';
  }

  final values = schemaNames
      .map((schemaName) => "N'${schemaName.replaceAll("'", "''")}'")
      .join(', ');
  return ' AND $column IN ($values)';
}

String _readString(Map<String, dynamic> row, String key) {
  final value = _readValue(row, key);
  if (value == null) {
    throw StateError('Expected non-null value for $key');
  }

  return value.toString();
}

int _readInt(Map<String, dynamic> row, String key) {
  final value = _readValue(row, key);
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }

  final parsed = int.tryParse(value.toString());
  if (parsed != null) {
    return parsed;
  }

  throw StateError('Expected integer value for $key, got $value');
}

bool _readBool(Map<String, dynamic> row, String key) {
  final value = _readValue(row, key);
  if (value is bool) {
    return value;
  }
  if (value is int) {
    return value != 0;
  }
  if (value is num) {
    return value.toInt() != 0;
  }

  final normalized = value.toString().trim().toLowerCase();
  if (normalized == '1' || normalized == 'true') {
    return true;
  }
  if (normalized == '0' || normalized == 'false') {
    return false;
  }

  throw StateError('Expected boolean value for $key, got $value');
}

Object? _readValue(Map<String, dynamic> row, String key) {
  if (row.containsKey(key)) {
    return row[key];
  }

  for (final entry in row.entries) {
    if (entry.key.toLowerCase() == key.toLowerCase()) {
      return entry.value;
    }
  }

  throw StateError('Missing expected SQL Server metadata column: $key');
}

String _formatNativeType({
  required String typeName,
  required int maxLength,
  required int precision,
  required int scale,
}) {
  switch (typeName.toLowerCase()) {
    case 'nvarchar':
    case 'nchar':
      final length = maxLength == -1 ? 'max' : (maxLength ~/ 2).toString();
      return '$typeName($length)';
    case 'varchar':
    case 'char':
    case 'varbinary':
    case 'binary':
      final length = maxLength == -1 ? 'max' : maxLength.toString();
      return '$typeName($length)';
    case 'decimal':
    case 'numeric':
      return '$typeName($precision,$scale)';
    case 'datetime2':
    case 'datetimeoffset':
    case 'time':
      return '$typeName($scale)';
    default:
      return typeName;
  }
}

final class _PhysicalObjectAccumulator {
  _PhysicalObjectAccumulator({
    required this.id,
    required this.kind,
    required this.schemaName,
    required this.objectName,
  });

  final String id;
  final PhysicalObjectKind kind;
  final String schemaName;
  final String objectName;
  final List<String> identityFields = <String>[];
  final List<PhysicalField> fields = <PhysicalField>[];
  final List<PhysicalRelationSeed> relations = <PhysicalRelationSeed>[];

  PhysicalObject build() {
    return PhysicalObject(
      id: id,
      kind: kind,
      schemaName: schemaName,
      objectName: objectName,
      identityFields: List<String>.unmodifiable(identityFields),
      fields: List<PhysicalField>.unmodifiable(fields),
      relations: List<PhysicalRelationSeed>.unmodifiable(relations),
    );
  }
}

final class _RelationAccumulator {
  _RelationAccumulator({
    required this.name,
    required this.sourceObjectId,
    required this.targetObjectId,
  });

  final String name;
  final String sourceObjectId;
  final String targetObjectId;
  final List<String> sourceFields = <String>[];
  final List<String> targetFields = <String>[];
}