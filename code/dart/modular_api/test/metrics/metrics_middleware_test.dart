import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:modular_api/src/core/metrics/metric.dart';
import 'package:modular_api/src/core/metrics/metric_registry.dart';
import 'package:modular_api/src/core/metrics/metrics_middleware.dart';

void main() {
  // ── metricsMiddleware ──────────────────────────────────────────────────

  group('metricsMiddleware', () {
    late MetricRegistry registry;
    late Counter requestsTotal;
    late Gauge requestsInFlight;
    late Histogram requestDuration;

    Response okHandler(Request request) {
      return Response.ok(
        jsonEncode({'ok': true}),
        headers: {'content-type': 'application/json'},
      );
    }

    Handler slowHandler(Duration delay) {
      return (Request request) async {
        await Future.delayed(delay);
        return Response.ok('done');
      };
    }

    setUp(() {
      registry = MetricRegistry();
      requestsTotal = registry.createCounter(
        name: 'http_requests_total',
        help: 'Total HTTP requests',
      );
      requestsInFlight = registry.createGauge(
        name: 'http_requests_in_flight',
        help: 'Concurrent requests',
      );
      requestDuration = registry.createHistogram(
        name: 'http_request_duration_seconds',
        help: 'Request duration',
      );
    });

    Middleware createMiddleware({
      List<String> excludedRoutes = const [],
      List<String> registeredPaths = const [],
    }) {
      return metricsMiddleware(
        requestsTotal: requestsTotal,
        requestsInFlight: requestsInFlight,
        requestDuration: requestDuration,
        excludedRoutes: excludedRoutes,
        registeredPaths: registeredPaths,
      );
    }

    test('increments http_requests_total with correct labels', () async {
      final mw = createMiddleware(
        registeredPaths: ['/api/greetings/hello'],
      );
      final handler = mw(okHandler);

      await handler(
        Request('POST', Uri.parse('http://localhost/api/greetings/hello')),
      );

      final samples = requestsTotal.collect();
      expect(samples, hasLength(1));
      expect(samples.first.labels['method'], equals('POST'));
      expect(samples.first.labels['status_code'], equals('200'));
      expect(samples.first.labels['route'], equals('/api/greetings/hello'));
      expect(samples.first.value, equals(1.0));
    });

    test('method label is uppercase', () async {
      final mw = createMiddleware();
      final handler = mw(okHandler);

      await handler(
        Request('GET', Uri.parse('http://localhost/api/test')),
      );

      final samples = requestsTotal.collect();
      expect(samples.first.labels['method'], equals('GET'));
    });

    test('status_code label is string', () async {
      final mw = createMiddleware();
      Response errorHandler(Request request) =>
          Response(404, body: 'not found');
      final handler = mw(errorHandler);

      await handler(
        Request('GET', Uri.parse('http://localhost/api/missing')),
      );

      final samples = requestsTotal.collect();
      expect(samples.first.labels['status_code'], equals('404'));
    });

    test('unmatched route uses UNMATCHED label', () async {
      final mw = createMiddleware(
        registeredPaths: ['/api/greetings/hello'],
      );
      final handler = mw(okHandler);

      await handler(
        Request('GET', Uri.parse('http://localhost/api/unknown')),
      );

      final samples = requestsTotal.collect();
      expect(samples.first.labels['route'], equals('UNMATCHED'));
    });

    test('observes request duration in histogram', () async {
      final mw = createMiddleware();
      final handler = mw(slowHandler(Duration(milliseconds: 50)));

      await handler(
        Request('GET', Uri.parse('http://localhost/api/slow')),
      );

      final samples = requestDuration.collect();
      final countSample = samples.firstWhere((s) => s.suffix == '_count');
      expect(countSample.value, equals(1.0));

      final sumSample = samples.firstWhere((s) => s.suffix == '_sum');
      // Duration should be at least 40ms (0.04s) — allow some tolerance
      expect(sumSample.value, greaterThan(0.04));
    });

    test('manages in-flight gauge (increments then decrements)', () async {
      // After request completes, in-flight should be back to 0.
      final mw = createMiddleware();
      final handler = mw(okHandler);

      await handler(
        Request('GET', Uri.parse('http://localhost/api/test')),
      );

      // After completion, gauge should be back at 0.
      expect(requestsInFlight.value, equals(0.0));
    });

    test('excludes configured routes', () async {
      final mw = createMiddleware(
        excludedRoutes: ['/metrics', '/health'],
      );
      final handler = mw(okHandler);

      await handler(
        Request('GET', Uri.parse('http://localhost/metrics')),
      );
      await handler(
        Request('GET', Uri.parse('http://localhost/health')),
      );

      // No metrics should be recorded for excluded routes.
      expect(requestsTotal.collect(), isEmpty);
    });

    test('does not exclude non-matching routes', () async {
      final mw = createMiddleware(
        excludedRoutes: ['/metrics'],
      );
      final handler = mw(okHandler);

      await handler(
        Request('GET', Uri.parse('http://localhost/api/data')),
      );

      expect(requestsTotal.collect(), hasLength(1));
    });

    test('accumulates across multiple requests', () async {
      final mw = createMiddleware(
        registeredPaths: ['/api/test'],
      );
      final handler = mw(okHandler);

      await handler(
        Request('GET', Uri.parse('http://localhost/api/test')),
      );
      await handler(
        Request('GET', Uri.parse('http://localhost/api/test')),
      );
      await handler(
        Request('POST', Uri.parse('http://localhost/api/test')),
      );

      final samples = requestsTotal.collect();
      // Two label combos: GET/200, POST/200
      expect(samples, hasLength(2));

      final getSample = samples.firstWhere(
        (s) => s.labels['method'] == 'GET',
      );
      expect(getSample.value, equals(2.0));
    });

    test('handles handler exception gracefully', () async {
      final mw = createMiddleware();
      Response throwingHandler(Request request) => throw Exception('boom');
      final handler = mw(throwingHandler);

      try {
        await handler(
          Request('GET', Uri.parse('http://localhost/api/broken')),
        );
      } catch (_) {
        // Exception propagates
      }

      // Even on exception, in_flight should decrement.
      expect(requestsInFlight.value, equals(0.0));
      // request_total should record a 500
      final samples = requestsTotal.collect();
      expect(samples, hasLength(1));
      expect(samples.first.labels['status_code'], equals('500'));
    });
  });

  // ── metricsHandler ────────────────────────────────────────────────────

  group('metricsHandler', () {
    late MetricRegistry registry;

    setUp(() {
      registry = MetricRegistry();
    });

    test('returns 200 with prometheus content type', () async {
      final handler = metricsHandler(registry);
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/metrics')),
      );

      expect(response.statusCode, equals(200));
      expect(
        response.headers['content-type'],
        equals('text/plain; version=0.0.4; charset=utf-8'),
      );
    });

    test('body contains serialized metrics', () async {
      registry.createCounter(name: 'test_total', help: 'A test');
      final handler = metricsHandler(registry);
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/metrics')),
      );

      final body = await response.readAsString();
      expect(body, contains('# HELP test_total A test'));
      expect(body, contains('# TYPE test_total counter'));
    });

    test('body contains process_start_time_seconds', () async {
      final handler = metricsHandler(registry);
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/metrics')),
      );

      final body = await response.readAsString();
      expect(body, contains('process_start_time_seconds'));
    });
  });
}
