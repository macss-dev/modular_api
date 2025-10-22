// lib/src/swagger/swagger.dart
import 'dart:convert';
import 'package:modular_api/src/core/modular_api.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_swagger_ui/shelf_swagger_ui.dart';

class OpenApi {
  static late Handler docs;

  static Future<void> init({
    String title = 'Modular API',
    required int port,
    List<Map<String, String>>? servers,
  }) async {
    final swaggerJsonString =
        await jsonStringFromSchema(title: title, servers: servers, port: port);
    final ui = SwaggerUI(swaggerJsonString, title: title); // wrapper
    docs = ui.call;
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
        'version': '1.0.0',
        'description': 'Auto-generated from ModularApi using DTO.toSchema()',
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
      final inputRefName = '${r.module}_${r.name}_Input';
      final outputRefName = '${r.module}_${r.name}_Output';
      compSchemas[inputRefName] = inputSchema;
      compSchemas[outputRefName] = outputSchema;

      // 4) Build operation
      final op = <String, dynamic>{
        'tags': r.doc?.tags ?? [r.module],
        'operationId': '${r.module}_${r.name}_${r.method.toLowerCase()}',
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

  /// Attempts to construct the UseCase with {} and read input.toSchema()
  /// Requires fromJson to be tolerant (not throw).
  static Map<String, dynamic> _inferInputSchema(UseCaseRegistration r) {
    try {
      final uc = r.factory(<String, dynamic>{});
      final schema = uc.input.toSchema();
      // Sanitize: ensure at least 'type: object'
      if (schema['type'] == null) {
        schema['type'] = 'object';
      }
      return schema;
    } catch (_) {
      // Fallback si fromJson lanza
      return {'type': 'object', 'properties': {}};
    }
  }

  static Map<String, dynamic> _inferOutputSchema(UseCaseRegistration r) {
    try {
      final uc = r.factory(<String, dynamic>{});
      final schema = uc.output.toSchema();
      // Sanitize: ensure at least 'type: object'
      if (schema['type'] == null) {
        schema['type'] = 'object';
      }
      return schema;
    } catch (_) {
      // Fallback if fromJson throws
      return {'type': 'object', 'properties': {}};
    }
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
