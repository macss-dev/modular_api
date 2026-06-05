import 'package:modular_api/src/core/logger/logger.dart';
import 'package:modular_api/src/core/schema/field.dart';

/// **Contract** — use `implements UseCase<I, O>`.
///
/// Pure interface: all members must be provided by the implementor.
/// No default behavior is inherited — every UseCase is self-contained.
///
/// Lifecycle (handled by the framework):
///   1. `fromJson(json)`    — static factory, builds the use case
///   2. `validate()`        — return error string or null
///   3. `execute()`         — run business logic, return Output
///   4. handler serializes  — `output.toJson()` → HTTP response
abstract class UseCase<I extends Input, O extends Output> {
  /// Input DTO — set in constructor via fromJson.
  I get input;

  /// Logger scoped to the current HTTP request.
  /// Set by the framework before [execute] is called.
  /// Use `logger?.info(...)` etc. inside [execute] for structured logging.
  ModularLogger? logger;

  /// Read from DTO
  /// Deserialize the use case data from JSON
  factory UseCase.fromJson(Map<String, dynamic> json) {
    throw UnimplementedError('Must implement fromJson');
  }

  /// Validate the use case data
  String? validate();

  /// Execute the use case logic and return the Output.
  /// Business logic should be implemented here.
  Future<O> execute();
}

/// **Contract** — use `implements Input`.
///
/// When a subclass provides [schemaFields], [toSchema] is derived
/// automatically. Manual overrides still work (deprecated — will be
/// removed in v0.5.0).
///
/// ```dart
/// class HelloInput implements Input {
///   final String name;
///
///   HelloInput({required this.name});
///
///   factory HelloInput.fromJson(Map<String, dynamic> json) =>
///       HelloInput(name: (json['name'] ?? '').toString());
///
///   @override
///   Map<String, dynamic> toJson() => {'name': name};
///
///   @override
///   List<SchemaField> get schemaFields => [
///     SchemaField.string('name', description: 'Name to greet'),
///   ];
/// }
/// ```
abstract class Input {
  /// Generative constructor — enables `extends Input` for auto-schema.
  Input();

  /// El contrato no impone fromJson;
  factory Input.fromJson(Map<String, dynamic> json) {
    throw UnimplementedError('Must implement fromJson');
  }
  Map<String, dynamic> toJson();

  /// Override to provide field metadata for automatic schema generation.
  /// When provided, [toSchema] is derived automatically.
  /// Returns `null` by default (legacy path — manual toSchema required).
  List<SchemaField>? get schemaFields => null;

  /// Schema — required for OpenAPI specification.
  /// When [schemaFields] is provided, the schema is derived automatically.
  /// Otherwise, infers types from [toJson] values (less detail, no descriptions).
  Map<String, dynamic> toSchema() {
    final fields = schemaFields;
    if (fields != null) {
      return buildSchema(fields);
    }
    // Fallback: infer schema from toJson() value types
    return inferSchemaFromExample(toJson());
  }
}

/// **Contract** — use `implements Output`.
///
/// When a subclass provides [schemaFields], [toSchema] is derived
/// automatically. The implementor must define `statusCode` explicitly —
/// this forces developers to think about HTTP status codes for every response.
abstract class Output {
  /// Generative constructor — enables `extends Output` for auto-schema.
  Output();

  Map<String, dynamic> toJson();

  /// Override to provide field metadata for automatic schema generation.
  List<SchemaField>? get schemaFields => null;

  /// Schema — required for OpenAPI specification.
  /// When [schemaFields] is provided, the schema is derived automatically.
  /// Otherwise, infers types from [toJson] values (less detail, no descriptions).
  Map<String, dynamic> toSchema() {
    final fields = schemaFields;
    if (fields != null) {
      return buildSchema(fields);
    }
    // Fallback: infer schema from toJson() value types
    return inferSchemaFromExample(toJson());
  }

  /// HTTP status code to return.
  /// Must be implemented explicitly (e.g. 200, 201, 400, 404).
  int get statusCode;
}
