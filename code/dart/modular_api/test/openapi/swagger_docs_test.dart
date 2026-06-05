import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:modular_api/modular_api.dart';
import 'package:modular_api/src/core/modular_api.dart' show apiRegistry;
import 'package:test/test.dart';

/// Assertions for GET /api/docs — docs-ui CDN widget.
///
///   1. GET /docs returns HTTP 200.
///   2. Content-Type header is text/html; charset=utf-8.
///   3. Response body contains @macss/docs-ui CDN reference.
///   4. Response body contains DocsUI.init bootloader call.
///   5. Response body does NOT contain "scalar" (regression guard).
void main() {
  group('GET /api/docs — docs-ui (PRD-003)', () {
    late HttpServer server;
    late int port;

    setUp(() async {
      apiRegistry.routes.clear();

      final api = ModularApi(
        basePath: '/api',
        title: 'Pet Store',
        version: '1.0.0',
      );

      server = await api.serve(port: 0);
      port = server.port;
    });

    tearDown(() async {
      await server.close(force: true);
      apiRegistry.routes.clear();
    });

    test('returns HTTP 200', () async {
      final resp = await http.get(Uri.parse('http://localhost:$port/api/docs'));
      expect(resp.statusCode, 200);
    });

    test('returns Content-Type text/html', () async {
      final resp = await http.get(Uri.parse('http://localhost:$port/api/docs'));
      expect(resp.headers['content-type'], contains('text/html'));
    });

    test('body contains @macss/docs-ui CDN reference', () async {
      final resp = await http.get(Uri.parse('http://localhost:$port/api/docs'));
      expect(resp.body, contains('@macss/docs-ui'));
    });

    test('body contains DocsUI.init bootloader', () async {
      final resp = await http.get(Uri.parse('http://localhost:$port/api/docs'));
      expect(resp.body, contains('DocsUI.init'));
    });

    test('body contains specUrl pointing to /api/openapi.json', () async {
      final resp = await http.get(Uri.parse('http://localhost:$port/api/docs'));
      expect(resp.body, contains('/api/openapi.json'));
    });

    test('body does NOT contain scalar (PRD-003 regression guard)', () async {
      final resp = await http.get(Uri.parse('http://localhost:$port/api/docs'));
      expect(resp.body.toLowerCase(), isNot(contains('scalar')));
    });

    test('interpolates the API title in the HTML', () async {
      final resp = await http.get(Uri.parse('http://localhost:$port/api/docs'));
      expect(resp.body, contains('Pet Store'));
    });

    test('returns a complete HTML document', () async {
      final resp = await http.get(Uri.parse('http://localhost:$port/api/docs'));
      expect(resp.body, contains('<!DOCTYPE html>'));
      expect(resp.body, contains('</html>'));
    });

    // ── Dark mode is now handled by @macss/docs-ui — tested in docs-ui/
  });
}
