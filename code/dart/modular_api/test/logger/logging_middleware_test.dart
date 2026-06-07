import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:modular_api/src/core/logger/logger.dart';
import 'package:modular_api/src/core/logger/logging_middleware.dart';

void main() {
  late StringBuffer logOutput;

  /// Helper: build a pipeline with loggingMiddleware + inner handler.
  Handler buildHandler(
    Handler innerHandler, {
    LogLevel logLevel = LogLevel.debug,
    List<String> excludedRoutes = const [],
  }) {
    final mw = loggingMiddleware(
      logLevel: logLevel,
      serviceName: 'test-svc',
      excludedRoutes: excludedRoutes,
      sink: logOutput,
    );
    return const Pipeline().addMiddleware(mw).addHandler(innerHandler);
  }

  /// Helper: create a fake Shelf Request.
  Request req(String method, String path, {Map<String, String>? headers}) {
    return Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: headers,
    );
  }

  setUp(() {
    logOutput = StringBuffer();
  });

  // ─── trace_id generation ─────────────────────────────────────────

  group('trace_id', () {
    test('generates a UUID v4 when X-Request-ID header is absent', () async {
      final handler = buildHandler(
        (req) => Response.ok('ok'),
      );

      await handler(req('GET', '/api/test'));

      final lines = logOutput.toString().trim().split('\n');
      // At least 2 logs: request received + request completed
      expect(lines.length, greaterThanOrEqualTo(2));

      final first = jsonDecode(lines[0]) as Map<String, dynamic>;
      final traceId = first['trace_id'] as String;

      // UUID v4 format
      expect(
        traceId,
        matches(RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
      );
    });

    test('uses X-Request-ID header value when present', () async {
      final handler = buildHandler(
        (req) => Response.ok('ok'),
      );

      await handler(req('POST', '/api/test',
          headers: {'X-Request-ID': 'custom-trace-abc'}));

      final lines = logOutput.toString().trim().split('\n');
      final first = jsonDecode(lines[0]) as Map<String, dynamic>;
      expect(first['trace_id'], 'custom-trace-abc');
    });

    test('same trace_id is used in both request and response logs', () async {
      final handler = buildHandler(
        (req) => Response.ok('ok'),
      );

      await handler(req('GET', '/api/check'));

      final lines = logOutput.toString().trim().split('\n');
      expect(lines.length, 2);

      final reqLog = jsonDecode(lines[0]) as Map<String, dynamic>;
      final res = jsonDecode(lines[1]) as Map<String, dynamic>;
      expect(reqLog['trace_id'], equals(res['trace_id']));
    });

    test('X-Request-ID response header contains the used trace_id', () async {
      final handler = buildHandler(
        (req) => Response.ok('ok'),
      );

      final response = await handler(req('GET', '/api/test'));

      expect(response.headers['X-Request-ID'], isNotNull);
      expect(response.headers['X-Request-ID'], isNotEmpty);

      // Verify it matches the trace_id in logs
      final lines = logOutput.toString().trim().split('\n');
      final first = jsonDecode(lines[0]) as Map<String, dynamic>;
      expect(response.headers['X-Request-ID'], first['trace_id']);
    });
  });

  // ─── Request received log ────────────────────────────────────────

  group('request received log', () {
    test('emits "request received" as first log with info level', () async {
      final handler = buildHandler((req) => Response.ok('ok'));

      await handler(req('POST', '/api/users/create'));

      final lines = logOutput.toString().trim().split('\n');
      final first = jsonDecode(lines[0]) as Map<String, dynamic>;
      expect(first['msg'], 'request received');
      expect(first['level'], 'info');
      expect(first['severity'], 6);
    });

    test('includes method and route fields', () async {
      final handler = buildHandler((req) => Response.ok('ok'));

      await handler(req('POST', '/api/users/create'));

      final lines = logOutput.toString().trim().split('\n');
      final first = jsonDecode(lines[0]) as Map<String, dynamic>;
      expect(first['method'], 'POST');
      expect(first['route'], '/api/users/create');
    });

    test('includes service name', () async {
      final handler = buildHandler((req) => Response.ok('ok'));

      await handler(req('GET', '/api/health'));

      final lines = logOutput.toString().trim().split('\n');
      final first = jsonDecode(lines[0]) as Map<String, dynamic>;
      expect(first['service'], 'test-svc');
    });
  });

  // ─── Request completed log ───────────────────────────────────────

  group('request completed log', () {
    test('emits "request completed" with status and duration_ms', () async {
      final handler = buildHandler((req) => Response.ok('ok'));

      await handler(req('GET', '/api/test'));

      final lines = logOutput.toString().trim().split('\n');
      final last = jsonDecode(lines.last) as Map<String, dynamic>;
      expect(last['msg'], 'request completed');
      expect(last['status'], 200);
      expect(last['duration_ms'], isA<num>());
      expect((last['duration_ms'] as num).toDouble(), greaterThanOrEqualTo(0));
    });

    test('includes method and route', () async {
      final handler = buildHandler((req) => Response.ok('ok'));

      await handler(req('PUT', '/api/items/update'));

      final lines = logOutput.toString().trim().split('\n');
      final last = jsonDecode(lines.last) as Map<String, dynamic>;
      expect(last['method'], 'PUT');
      expect(last['route'], '/api/items/update');
    });
  });

  // ─── Status code → log level mapping ─────────────────────────────

  group('status code to log level mapping', () {
    test('2xx → info', () async {
      final handler = buildHandler((req) => Response(201));

      await handler(req('POST', '/api/test'));

      final lines = logOutput.toString().trim().split('\n');
      final last = jsonDecode(lines.last) as Map<String, dynamic>;
      expect(last['level'], 'info');
      expect(last['severity'], 6);
    });

    test('3xx → info', () async {
      final handler = buildHandler(
        (req) => Response(301, headers: {'location': '/new'}),
      );

      await handler(req('GET', '/api/old'));

      final lines = logOutput.toString().trim().split('\n');
      final last = jsonDecode(lines.last) as Map<String, dynamic>;
      expect(last['level'], 'info');
    });

    test('400 → warning', () async {
      final handler = buildHandler((req) => Response(400));

      await handler(req('POST', '/api/test'));

      final lines = logOutput.toString().trim().split('\n');
      final last = jsonDecode(lines.last) as Map<String, dynamic>;
      expect(last['level'], 'warning');
      expect(last['severity'], 4);
    });

    test('401 → warning', () async {
      final handler = buildHandler((req) => Response(401));

      await handler(req('GET', '/api/test'));

      final lines = logOutput.toString().trim().split('\n');
      final last = jsonDecode(lines.last) as Map<String, dynamic>;
      expect(last['level'], 'warning');
    });

    test('404 → warning', () async {
      final handler = buildHandler((req) => Response(404));

      await handler(req('GET', '/api/missing'));

      final lines = logOutput.toString().trim().split('\n');
      final last = jsonDecode(lines.last) as Map<String, dynamic>;
      expect(last['level'], 'warning');
    });

    test('500 → error', () async {
      final handler = buildHandler((req) => Response(500));

      await handler(req('POST', '/api/test'));

      final lines = logOutput.toString().trim().split('\n');
      final last = jsonDecode(lines.last) as Map<String, dynamic>;
      expect(last['level'], 'error');
      expect(last['severity'], 3);
    });

    test('503 → error', () async {
      final handler = buildHandler((req) => Response(503));

      await handler(req('POST', '/api/test'));

      final lines = logOutput.toString().trim().split('\n');
      final last = jsonDecode(lines.last) as Map<String, dynamic>;
      expect(last['level'], 'error');
    });

    test('1xx → notice', () async {
      final handler = buildHandler((req) => Response(100));

      await handler(req('GET', '/api/test'));

      final lines = logOutput.toString().trim().split('\n');
      final last = jsonDecode(lines.last) as Map<String, dynamic>;
      expect(last['level'], 'notice');
      expect(last['severity'], 5);
    });
  });

  // ─── Excluded routes ─────────────────────────────────────────────

  group('excluded routes', () {
    test('/health is not logged when excluded', () async {
      final handler = buildHandler(
        (req) => Response.ok('ok'),
        excludedRoutes: ['/health', '/metrics'],
      );

      await handler(req('GET', '/health'));

      expect(logOutput.toString(), isEmpty);
    });

    test('/metrics is not logged when excluded', () async {
      final handler = buildHandler(
        (req) => Response.ok('ok'),
        excludedRoutes: ['/health', '/metrics'],
      );

      await handler(req('GET', '/metrics'));

      expect(logOutput.toString(), isEmpty);
    });

    test('non-excluded routes are logged normally', () async {
      final handler = buildHandler(
        (req) => Response.ok('ok'),
        excludedRoutes: ['/health', '/metrics'],
      );

      await handler(req('POST', '/api/users/create'));

      final lines = logOutput.toString().trim().split('\n');
      expect(lines.length, 2); // request received + request completed
    });
  });

  // ─── Logger in request context ───────────────────────────────────

  group('logger propagation via context', () {
    test('logger is available in request context as RequestScopedLogger',
        () async {
      late ModularLogger? capturedLogger;

      final handler = buildHandler((req) {
        capturedLogger = req.context['modular.logger'] as ModularLogger?;
        return Response.ok('ok');
      });

      await handler(req('GET', '/api/test'));

      expect(capturedLogger, isNotNull);
      expect(capturedLogger, isA<RequestScopedLogger>());
    });

    test('logger in context has the same trace_id', () async {
      late RequestScopedLogger capturedLogger;

      final handler = buildHandler((req) {
        capturedLogger = req.context['modular.logger'] as RequestScopedLogger;
        return Response.ok('ok');
      });

      await handler(
          req('GET', '/api/test', headers: {'X-Request-ID': 'my-trace'}));

      expect(capturedLogger.traceId, 'my-trace');
    });
  });

  // ─── Unhandled exceptions ────────────────────────────────────────

  group('unhandled exceptions', () {
    test('exception in handler emits error log with status 500', () async {
      final handler = buildHandler(
        (req) => throw Exception('boom'),
      );

      // The middleware should catch and re-throw, but emit the error log first
      try {
        await handler(req('POST', '/api/fail'));
      } catch (_) {
        // expected
      }

      final lines = logOutput.toString().trim().split('\n');
      // Should have: request received + unhandled exception
      expect(lines.length, 2);

      final errorLog = jsonDecode(lines[1]) as Map<String, dynamic>;
      expect(errorLog['msg'], 'unhandled exception');
      expect(errorLog['level'], 'error');
      expect(errorLog['status'], 500);
      expect(errorLog['route'], '/api/fail');
      // Must NOT contain stack trace or exception message
      expect(errorLog.containsKey('stack'), isFalse);
      expect(errorLog.containsKey('exception'), isFalse);
    });
  });
}
