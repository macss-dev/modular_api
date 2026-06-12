import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';

// ADR-0003: plugin routes are first-class in OpenAPI and metrics.

class BinaryPlugin implements Plugin {
  @override
  PluginManifest get manifest => const PluginManifest(
        id: 'test.binary',
        displayName: 'Test Binary Plugin',
        version: '1.0.0',
        hostApiVersion: hostApiVersion,
      );

  @override
  void setup(PluginHost host) {
    host.registerRoute(
      PluginRoute(
        id: 'binary.foto.get',
        method: 'GET',
        path: '/binarios/foto',
        visibility: 'custom',
        openapi: {
          'summary': 'Devuelve el binario de una foto',
          'parameters': [
            {
              'name': 'nombre',
              'in': 'query',
              'required': true,
              'schema': {'type': 'string'},
            },
          ],
          'responses': {
            '200': {
              'description': 'Foto encontrada',
              'content': {
                'image/jpeg': {
                  'schema': {'type': 'string', 'format': 'binary'},
                },
              },
            },
            '404': {'description': 'Foto no encontrada'},
          },
        },
        handler: (context) => Response.ok(
          [0xff, 0xd8, 0xff, 0xe0],
          headers: {'content-type': 'image/jpeg'},
        ),
      ),
    );

    host.registerRoute(
      PluginRoute(
        id: 'binary.sin-doc.get',
        method: 'GET',
        path: '/binarios/sin-doc',
        visibility: 'custom',
        handler: (context) => Response.ok('ok'),
      ),
    );
  }
}

class ObserverPlugin implements Plugin, ValidatingPlugin {
  List<RegisteredPluginRouteView> captured = [];

  @override
  PluginManifest get manifest => const PluginManifest(
        id: 'test.observer',
        displayName: 'Test Observer Plugin',
        version: '1.0.0',
        hostApiVersion: hostApiVersion,
      );

  @override
  void setup(PluginHost host) {
    // sin rutas
  }

  @override
  List<PluginValidationResult> validate(PluginHost host) {
    captured = host.routes();
    return [];
  }
}

void main() {
  group('Plugin OpenAPI contributions (ADR-0003)', () {
    test('documents plugin routes that declare an openapi operation', () async {
      final api = ModularApi(basePath: '/api', title: 'ADR3', version: '1.0.0')
        ..plugin(BinaryPlugin());

      final server = await api.serve(port: 0);
      addTearDown(() => server.close(force: true));

      final spec = await http.get(
        Uri.parse('http://localhost:${server.port}/api/openapi.json'),
      );
      expect(spec.statusCode, 200);

      final body = jsonDecode(spec.body) as Map<String, dynamic>;
      final paths = (body['paths'] ?? {}) as Map<String, dynamic>;
      final pathItem = paths['/api/binarios/foto'] as Map<String, dynamic>?;
      expect(pathItem, isNotNull);

      final operation = pathItem!['get'] as Map<String, dynamic>?;
      expect(operation, isNotNull);
      expect(operation!['summary'], 'Devuelve el binario de una foto');
      final responses = operation['responses'] as Map<String, dynamic>;
      final ok = responses['200'] as Map<String, dynamic>;
      final content = ok['content'] as Map<String, dynamic>;
      final jpeg = content['image/jpeg'] as Map<String, dynamic>;
      final schema = jpeg['schema'] as Map<String, dynamic>;
      expect(schema['format'], 'binary');
    });

    test(
        'does not document plugin routes without an openapi operation, '
        'nor operational routes', () async {
      final api = ModularApi(basePath: '/api', title: 'ADR3', version: '1.0.0')
        ..plugin(BinaryPlugin());

      final server = await api.serve(port: 0);
      addTearDown(() => server.close(force: true));

      final spec = await http.get(
        Uri.parse('http://localhost:${server.port}/api/openapi.json'),
      );
      expect(spec.statusCode, 200);

      final body = jsonDecode(spec.body) as Map<String, dynamic>;
      final paths = (body['paths'] ?? {}) as Map<String, dynamic>;
      expect(paths['/api/binarios/sin-doc'], isNull);
      expect(paths['/api/health'], isNull);
      expect(paths['/api/openapi.json'], isNull);
    });

    test('exposes registered plugin routes through the host routes() view',
        () async {
      final observer = ObserverPlugin();
      final api = ModularApi(basePath: '/api', title: 'ADR3', version: '1.0.0')
        ..plugin(BinaryPlugin())
        ..plugin(observer);

      final server = await api.serve(port: 0);
      addTearDown(() => server.close(force: true));

      final fotoRoute = observer.captured
          .where((route) => route.path == '/api/binarios/foto')
          .toList();
      expect(fotoRoute, hasLength(1));
      expect(fotoRoute.single.pluginId, 'test.binary');
      expect(fotoRoute.single.method, 'GET');
      expect(fotoRoute.single.visibility, 'custom');
      expect(fotoRoute.single.openapi?['summary'],
          'Devuelve el binario de una foto');
    });

    test(
        'labels plugin routes with their real path in http_requests_total '
        '(not UNMATCHED)', () async {
      final api = ModularApi(
        basePath: '/api',
        title: 'ADR3',
        version: '1.0.0',
        metricsEnabled: true,
      )..plugin(BinaryPlugin());

      final server = await api.serve(port: 0);
      addTearDown(() => server.close(force: true));

      final baseUrl = 'http://localhost:${server.port}';
      final first = await http.get(Uri.parse('$baseUrl/api/binarios/foto'));
      expect(first.statusCode, 200);
      final second = await http.get(Uri.parse('$baseUrl/api/binarios/foto'));
      expect(second.statusCode, 200);

      final metrics = await http.get(Uri.parse('$baseUrl/api/metrics'));
      expect(metrics.statusCode, 200);
      expect(metrics.body, contains('route="/api/binarios/foto"'));
      expect(
        metrics.body,
        isNot(matches(RegExp(r'route="UNMATCHED"[^\n]*status_code="200"'))),
      );
    });
  });
}
