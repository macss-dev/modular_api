/// Schema field metadata for automatic `toSchema()` generation.
///
/// Dart does not have runtime reflection for annotations.
/// Instead of macros (experimental in Dart 3.5+), we use a declarative
/// `schemaFields` getter on Input/Output that lists field metadata.
/// The base class `Input.toSchema()` / `Output.toSchema()` builds the
/// OpenAPI 3.0.3-compatible JSON Schema automatically from this list.
///
/// ```dart
/// class HelloInput extends Input {
///   final String name;
///
///   HelloInput({required this.name});
///
///   @override
///   List<SchemaField> get schemaFields => [
///     SchemaField.string('name', description: 'Name to greet'),
///   ];
///   // toSchema() → auto-derived from schemaFields!
/// }
/// ```
library;

/// Metadata for a single schema field.
///
/// Used by [Input.toSchema] and [Output.toSchema] to build
/// OpenAPI 3.0.3-compatible JSON Schemas automatically.
class SchemaField {
  final String name;
  final String type;
  final String? description;
  final bool required;
  final bool nullable;
  final SchemaField? items;
  final dynamic example;

  const SchemaField(
    this.name,
    this.type, {
    this.description,
    this.required = true,
    this.nullable = false,
    this.items,
    this.example,
  });

  factory SchemaField.string(String name,
          {String? description, dynamic example}) =>
      SchemaField(name, 'string', description: description, example: example);

  factory SchemaField.integer(String name,
          {String? description, dynamic example}) =>
      SchemaField(name, 'integer', description: description, example: example);

  factory SchemaField.number(String name,
          {String? description, dynamic example}) =>
      SchemaField(name, 'number', description: description, example: example);

  factory SchemaField.boolean(String name,
          {String? description, dynamic example}) =>
      SchemaField(name, 'boolean', description: description, example: example);

  factory SchemaField.array(
    String name,
    SchemaField itemType, {
    String? description,
    dynamic example,
  }) =>
      SchemaField(name, 'array',
          description: description, items: itemType, example: example);

  factory SchemaField.object(String name,
          {String? description, dynamic example}) =>
      SchemaField(name, 'object', description: description, example: example);

  factory SchemaField.optional(SchemaField inner) => SchemaField(
        inner.name,
        inner.type,
        description: inner.description,
        required: false,
        nullable: true,
        items: inner.items,
        example: inner.example,
      );
}

/// Builds an OpenAPI 3.0.3 JSON Schema from a list of [SchemaField] entries.
Map<String, dynamic> buildSchema(List<SchemaField> fields) {
  final properties = <String, Map<String, dynamic>>{};
  final required = <String>[];

  final exampleValues = <String, dynamic>{};

  for (final field in fields) {
    final prop = <String, dynamic>{'type': field.type};
    if (field.description != null) {
      prop['description'] = field.description;
    }
    if (field.nullable) {
      prop['nullable'] = true;
    }
    if (field.items != null) {
      prop['items'] = {'type': field.items!.type};
    }
    if (field.example != null) {
      prop['example'] = field.example;
      exampleValues[field.name] = field.example;
    }
    properties[field.name] = prop;

    if (field.required) {
      required.add(field.name);
    }
  }

  final schema = <String, dynamic>{
    'type': 'object',
    'properties': properties,
  };
  if (required.isNotEmpty) {
    schema['required'] = required;
  }
  if (exampleValues.isNotEmpty) {
    schema['example'] = exampleValues;
  }
  return schema;
}

/// Infers an OpenAPI 3.0.3 JSON Schema from example values in a `toJson()` map.
///
/// Maps Dart runtime types to OpenAPI types:
///   - `String` → `string`
///   - `int` → `integer`
///   - `double` → `number`
///   - `bool` → `boolean`
///   - `List` → `array` (item type inferred from first element)
///   - `null` → `string` + `nullable: true` (excluded from required)
///
/// Used as fallback when [schemaFields] is not provided on an Input/Output.
Map<String, dynamic> inferSchemaFromExample(Map<String, dynamic> exampleJson) {
  final properties = <String, Map<String, dynamic>>{};
  final required = <String>[];

  for (final entry in exampleJson.entries) {
    final value = entry.value;
    if (value == null) {
      properties[entry.key] = {'type': 'string', 'nullable': true};
      continue;
    }

    final prop = <String, dynamic>{'type': _inferOpenApiType(value)};
    if (value is List) {
      prop['items'] = {
        'type': value.isEmpty ? 'string' : _inferOpenApiType(value.first),
      };
    }
    properties[entry.key] = prop;
    required.add(entry.key);
  }

  final schema = <String, dynamic>{
    'type': 'object',
    'properties': properties,
  };
  if (required.isNotEmpty) {
    schema['required'] = required;
  }
  return schema;
}

/// Maps a Dart runtime value to its OpenAPI 3.0.3 type string.
String _inferOpenApiType(dynamic value) {
  if (value is String) return 'string';
  if (value is int) return 'integer';
  if (value is double) return 'number';
  if (value is bool) return 'boolean';
  if (value is List) return 'array';
  if (value is Map) return 'object';
  return 'string';
}

/// Thrown by [validateJsonFields] when a required field is missing
/// or has the wrong JSON type.
///
/// Error messages follow the cross-SDK parity contract:
///   - `"Missing required field: {name}"`
///   - `"Field '{name}' must be of type {type}"`
class InputValidationException implements Exception {
  final String message;

  InputValidationException(this.message);

  @override
  String toString() => 'InputValidationException: $message';
}

/// Validates raw JSON against a list of [SchemaField] entries.
///
/// Throws [InputValidationException] when a required field is missing
/// or has the wrong JSON type. The handler catches this and returns 400.
///
/// Business-rule validation belongs in `UseCase.validate()` instead.
void validateJsonFields(Map<String, dynamic> json, List<SchemaField> fields) {
  for (final field in fields) {
    if (!field.required) continue;

    if (!json.containsKey(field.name) || json[field.name] == null) {
      throw InputValidationException('Missing required field: ${field.name}');
    }

    if (!_isJsonTypeValid(json[field.name], field.type)) {
      throw InputValidationException(
        "Field '${field.name}' must be of type ${field.type}",
      );
    }
  }
}

/// Checks whether a JSON value matches the expected OpenAPI type.
bool _isJsonTypeValid(dynamic value, String expectedType) {
  switch (expectedType) {
    case 'string':
      return value is String;
    case 'integer':
      return value is int;
    case 'number':
      return value is num;
    case 'boolean':
      return value is bool;
    case 'array':
      return value is List;
    case 'object':
      return value is Map;
    default:
      return true;
  }
}
