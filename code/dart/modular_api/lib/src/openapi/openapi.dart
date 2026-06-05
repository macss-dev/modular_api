// lib/src/swagger/swagger.dart
import 'dart:convert';
import 'package:modular_api/src/core/modular_api.dart';
import 'package:shelf/shelf.dart';

class OpenApi {
  /// Cached spec as JSON string (populated by [init]).
  static String _cachedJsonSpec = '';

  /// Cached spec as YAML string (populated by [init]).
  static String _cachedYamlSpec = '';

  static Future<void> init({
    String title = 'Modular API',
    required int port,
    List<Map<String, String>>? servers,
  }) async {
    final swaggerJsonString =
        await jsonStringFromSchema(title: title, servers: servers, port: port);
    _cachedJsonSpec = swaggerJsonString;
    _cachedYamlSpec = jsonToYaml(jsonDecode(swaggerJsonString));
  }

  /// Handler for GET /openapi.json — returns the OpenAPI spec as JSON.
  static Response openapiJson(Request request) {
    return Response.ok(
      _cachedJsonSpec,
      headers: {'content-type': 'application/json'},
    );
  }

  /// Handler for GET /openapi.yaml — returns the OpenAPI spec as YAML.
  static Response openapiYaml(Request request) {
    return Response.ok(
      _cachedYamlSpec,
      headers: {'content-type': 'application/x-yaml'},
    );
  }

  /// Converts a JSON-decoded value to a YAML string.
  /// Zero dependencies — handles maps, lists, strings, numbers, bools, and null.
  static String jsonToYaml(dynamic value, {int indent = 0}) {
    final buf = StringBuffer();
    _writeYaml(buf, value, indent, true);
    return buf.toString();
  }

  static void _writeYaml(
      StringBuffer buf, dynamic value, int indent, bool isRoot) {
    final pad = '  ' * indent;

    if (value is Map) {
      if (value.isEmpty) {
        buf.writeln('{}');
        return;
      }
      if (!isRoot) buf.writeln();
      for (final entry in value.entries) {
        buf.write('$pad${_yamlKey(entry.key.toString())}:');
        final v = entry.value;
        if (v is Map || v is List) {
          _writeYaml(buf, v, indent + 1, false);
        } else {
          buf.write(' ');
          _writeYamlScalar(buf, v);
          buf.writeln();
        }
      }
    } else if (value is List) {
      if (value.isEmpty) {
        buf.writeln('[]');
        return;
      }
      if (!isRoot) buf.writeln();
      for (final item in value) {
        if (item is Map || item is List) {
          buf.write('$pad- ');
          // For map items after '- ', write inline-ish with reduced indent
          if (item is Map && item.isNotEmpty) {
            var first = true;
            for (final e in item.entries) {
              if (first) {
                buf.write('${_yamlKey(e.key.toString())}:');
                first = false;
              } else {
                buf.write('$pad  ${_yamlKey(e.key.toString())}:');
              }
              final v = e.value;
              if (v is Map || v is List) {
                _writeYaml(buf, v, indent + 2, false);
              } else {
                buf.write(' ');
                _writeYamlScalar(buf, v);
                buf.writeln();
              }
            }
          } else {
            _writeYaml(buf, item, indent + 1, false);
          }
        } else {
          buf.write('$pad- ');
          _writeYamlScalar(buf, item);
          buf.writeln();
        }
      }
    } else {
      _writeYamlScalar(buf, value);
      buf.writeln();
    }
  }

  /// Writes a scalar YAML value (string, number, bool, null).
  static void _writeYamlScalar(StringBuffer buf, dynamic value) {
    if (value == null) {
      buf.write('null');
    } else if (value is bool) {
      buf.write(value ? 'true' : 'false');
    } else if (value is num) {
      buf.write(value);
    } else {
      final s = value.toString();
      if (_needsQuoting(s)) {
        buf.write("'${s.replaceAll("'", "''")}'");
      } else {
        buf.write(s);
      }
    }
  }

  /// Returns the key formatted for YAML. Quotes if necessary.
  static String _yamlKey(String key) {
    if (_needsQuoting(key)) {
      return "'${key.replaceAll("'", "''")}'";
    }
    return key;
  }

  /// Determines if a string value needs quoting in YAML.
  static bool _needsQuoting(String s) {
    if (s.isEmpty) return true;
    // Reserved YAML words
    const reserved = {
      'true',
      'false',
      'null',
      'yes',
      'no',
      'on',
      'off',
      'y',
      'n',
    };
    if (reserved.contains(s.toLowerCase())) return true;
    // Contains special chars that could break YAML parsing
    if (s.contains(RegExp(r'[:{}\[\],&*?|>!%#@`"\\]'))) return true;
    // Starts with special chars
    if (s.startsWith(RegExp(r'[-? ]'))) return true;
    // Looks like a number but is a string
    if (num.tryParse(s) != null) return true;
    // Contains newlines
    if (s.contains('\n')) return true;
    return false;
  }

  /// Builds the OpenAPI 3.0.0 specification
  static Future<String> jsonStringFromSchema(
      {required String title,
      required int port,
      required List<Map<String, String>>? servers}) async {
    // always add localhost to servers
    servers ??= [
      {'url': 'http://localhost:$port', 'description': 'Localhost'}
    ];

    final Map<String, dynamic> spec = {
      'openapi': '3.0.0',
      'info': {
        'title': title,
        'version': '0.1.0',
        'description': 'Auto-generated by modular_api',
      },
      // Keep absolute paths including basePath; root server "/"
      'servers': servers,
      'paths': <String, dynamic>{},
      'components': {'schemas': <String, dynamic>{}},
    };

    final paths = spec['paths'] as Map<String, dynamic>;
    final components = spec['components'] as Map<String, dynamic>;
    final compSchemas = components['schemas'] as Map<String, dynamic>;

    for (final r in apiRegistry.routes) {
      // 1) Infer input schema
      final inputSchema = _inferInputSchema(r);

      // 2) Obtain output schema (or generic fallback)
      final outputSchema = _inferOutputSchema(r);

      // 3) Name schemas for components (reusables)
      final safeCommand = r.command.replaceAll('-', '_');
      final inputRefName = '${r.module}_${safeCommand}_Input';
      final outputRefName = '${r.module}_${safeCommand}_Output';
      compSchemas[inputRefName] = inputSchema;
      compSchemas[outputRefName] = outputSchema;

      // 4) Build operation
      final op = <String, dynamic>{
        'tags': r.doc?.tags ?? [r.module],
        'operationId': '${r.module}_${safeCommand}_${r.method.toLowerCase()}',
        if (r.doc?.summary != null) 'summary': r.doc!.summary,
        if (r.doc?.description != null) 'description': r.doc!.description,
        'responses': {
          '200': {
            'description': 'OK',
            'content': {
              'application/json': {
                'schema': {'\$ref': '#/components/schemas/$outputRefName'},
              },
            },
          },
          '400': {'description': 'Bad Request'},
          '500': {'description': 'Internal Server Error'},
        },
      };

      // requestBody/parameters according to method
      if (r.method == 'GET') {
        // For GET: query parameters from the flat schema (top-level properties)
        op['parameters'] = _queryParamsFromSchema(inputSchema);
      } else {
        op['requestBody'] = {
          'required': true,
          'content': {
            'application/json': {
              'schema': {'\$ref': '#/components/schemas/$inputRefName'},
            },
          },
        };
      }

      // 5) Insert into paths
      final methodKey = r.method.toLowerCase();
      paths.putIfAbsent(r.path, () => <String, dynamic>{});
      (paths[r.path] as Map<String, dynamic>)[methodKey] = op;
    }

    return const JsonEncoder.withIndent('  ').convert(spec);
  }

  /// Extracts the input schema from the required example instance.
  ///
  /// The schema is built from the example (via schemaFields or type inference)
  /// and `schema['example']` is set to the example's serialized JSON.
  static Map<String, dynamic> _inferInputSchema(UseCaseRegistration r) {
    final schema = r.inputExample.toSchema();
    if (schema['type'] == null) schema['type'] = 'object';
    final exampleJson = r.inputExample.toJson();
    if (exampleJson.isNotEmpty) schema['example'] = exampleJson;
    return schema;
  }

  /// Extracts the output schema from the required example instance.
  static Map<String, dynamic> _inferOutputSchema(UseCaseRegistration r) {
    final schema = r.outputExample.toSchema();
    if (schema['type'] == null) schema['type'] = 'object';
    final exampleJson = r.outputExample.toJson();
    if (exampleJson.isNotEmpty) schema['example'] = exampleJson;
    return schema;
  }

  /// Converts a flat schema into query parameters (top-level properties only).
  /// For nested objects/arrays, consider using POST (deliberate limitation).
  static List<Map<String, dynamic>> _queryParamsFromSchema(
    Map<String, dynamic> schema,
  ) {
    final props = (schema['properties'] as Map<String, dynamic>?) ?? const {};
    final requiredList =
        (schema['required'] as List?)?.cast<String>().toSet() ?? <String>{};

    final params = <Map<String, dynamic>>[];
    props.forEach((key, value) {
      final prop = (value as Map).cast<String, dynamic>();
      final type = (prop['type'] ?? 'string').toString();
      params.add({
        'name': key,
        'in': 'query',
        'required': requiredList.contains(key),
        'schema': {'type': type},
        if (prop['description'] != null) 'description': prop['description'],
      });
    });

    return params;
  }
}
