import 'dart:convert';
import 'dart:io';

import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';

void main() {
  test('official operational endpoints resolve under the shared basePath', () async {
    final api = ModularApi(
      basePath: '/api',
      title: 'Plugin Ops',
      version: '1.0.0',
      metricsEnabled: true,
    );

    final server = await api.serve(port: 0);
    addTearDown(() => server.close(force: true));

    final client = HttpClient();
    addTearDown(client.close);

    final health = await _getJson(client, server.port, '/api/health');
    expect(health.$1, 200);
    expect((health.$2 as Map<String, dynamic>)['status'], 'pass');

    final metrics = await _getText(client, server.port, '/api/metrics');
    expect(metrics.$1, 200);
    expect(metrics.$2, contains('http_requests_total'));

    final openApiJson = await _getJson(client, server.port, '/api/openapi.json');
    expect(openApiJson.$1, 200);
    expect((openApiJson.$2 as Map<String, dynamic>)['openapi'], '3.0.0');

    final openApiYaml = await _getText(client, server.port, '/api/openapi.yaml');
    expect(openApiYaml.$1, 200);
    expect(openApiYaml.$2, contains('openapi: 3.0.0'));

    final docs = await _getText(client, server.port, '/api/docs');
    expect(docs.$1, 200);
    expect(docs.$2, contains('/api/openapi.json'));

    expect((await _getText(client, server.port, '/health')).$1, 404);
    expect((await _getText(client, server.port, '/metrics')).$1, 404);
    expect((await _getText(client, server.port, '/openapi.json')).$1, 404);
    expect((await _getText(client, server.port, '/openapi.yaml')).$1, 404);
    expect((await _getText(client, server.port, '/docs')).$1, 404);
  });
}

Future<(int, Object?)> _getJson(HttpClient client, int port, String path) async {
  final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
  final response = await request.close();
  final body = await utf8.decodeStream(response);
  return (response.statusCode, jsonDecode(body));
}

Future<(int, String)> _getText(HttpClient client, int port, String path) async {
  final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
  final response = await request.close();
  final body = await utf8.decodeStream(response);
  return (response.statusCode, body);
}