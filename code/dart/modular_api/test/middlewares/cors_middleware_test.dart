/// Tests for corsMiddleware — Shelf middleware that sets CORS headers.
///
/// Mirrors test_cors.py (Python) to ensure cross-SDK parity.
library;

import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';

// ── Helpers ──────────────────────────────────────────────────

/// Simple handler that returns 200 with a plain text body.
Handler _echoHandler() => (Request request) => Response.ok('ok');

/// Applies [corsMiddleware] with given options and sends [request] through it.
Future<Response> _send(
  Request request, {
  Object? origin,
  String? methods,
  String? allowedHeaders,
}) async {
  final middleware = corsMiddleware(
    origin: origin,
    methods: methods,
    allowedHeaders: allowedHeaders,
  );
  final handler = middleware(_echoHandler());
  return handler(request);
}

Request _get(String path) => Request('GET', Uri.parse('http://localhost$path'));

Request _post(String path) =>
    Request('POST', Uri.parse('http://localhost$path'));

Request _options(String path) =>
    Request('OPTIONS', Uri.parse('http://localhost$path'));

// ── Default CORS headers ────────────────────────────────────

void main() {
  group('corsMiddleware — default headers', () {
    test('sets Access-Control-Allow-Origin to * by default', () async {
      final response = await _send(_get('/echo'));
      expect(response.headers['access-control-allow-origin'], equals('*'));
    });

    test('sets default methods including GET, POST, OPTIONS', () async {
      final response = await _send(_get('/echo'));
      final methods = response.headers['access-control-allow-methods']!;
      expect(methods, contains('GET'));
      expect(methods, contains('POST'));
      expect(methods, contains('OPTIONS'));
    });

    test('sets default allowed headers Content-Type and Authorization',
        () async {
      final response = await _send(_get('/echo'));
      final headers = response.headers['access-control-allow-headers']!;
      expect(headers, contains('Content-Type'));
      expect(headers, contains('Authorization'));
    });

    test('adds CORS headers to non-OPTIONS requests', () async {
      final response = await _send(_post('/echo'));
      expect(response.headers['access-control-allow-origin'], equals('*'));
    });
  });

  // ── OPTIONS preflight ───────────────────────────────────────

  group('corsMiddleware — OPTIONS preflight', () {
    test('responds 204 to OPTIONS requests', () async {
      final response = await _send(_options('/echo'));
      expect(response.statusCode, equals(204));
    });

    test('includes all CORS headers on OPTIONS response', () async {
      final response = await _send(_options('/echo'));
      expect(response.headers, contains('access-control-allow-origin'));
      expect(response.headers, contains('access-control-allow-methods'));
      expect(response.headers, contains('access-control-allow-headers'));
    });

    test('OPTIONS response body is empty', () async {
      final response = await _send(_options('/echo'));
      final body = await response.readAsString();
      expect(body, isEmpty);
    });
  });

  // ── Configurable origin, methods, headers ───────────────────

  group('corsMiddleware — custom options', () {
    test('sets custom origin when provided as string', () async {
      final response =
          await _send(_get('/echo'), origin: 'https://example.com');
      expect(response.headers['access-control-allow-origin'],
          equals('https://example.com'));
    });

    test('joins multiple origins when provided as list', () async {
      final response = await _send(
        _get('/echo'),
        origin: ['https://a.com', 'https://b.com'],
      );
      expect(response.headers['access-control-allow-origin'],
          equals('https://a.com, https://b.com'));
    });

    test('sets custom methods when provided', () async {
      final response = await _send(_get('/echo'), methods: 'GET,POST');
      expect(
          response.headers['access-control-allow-methods'], equals('GET,POST'));
    });

    test('sets custom allowed headers when provided', () async {
      final response =
          await _send(_get('/echo'), allowedHeaders: 'X-Custom-Header');
      expect(response.headers['access-control-allow-headers'],
          equals('X-Custom-Header'));
    });
  });
}
