import 'package:test/test.dart';
import 'package:modular_api/src/core/metrics/metric.dart';
import 'package:modular_api/src/core/metrics/metric_registry.dart';

void main() {
  // ── MetricRegistry ────────────────────────────────────────────────────

  group('MetricRegistry', () {
    late MetricRegistry registry;

    setUp(() {
      registry = MetricRegistry();
    });

    test('registers process_start_time_seconds on construction', () {
      final output = registry.serialize();
      expect(output, contains('process_start_time_seconds'));
      expect(output, contains('# TYPE process_start_time_seconds gauge'));
    });

    test('process_start_time_seconds is set to epoch seconds', () {
      final output = registry.serialize();
      // Extract the value line — it should be a reasonable epoch timestamp
      final lines = output.split('\n');
      final valueLine = lines.firstWhere(
        (l) => l.startsWith('process_start_time_seconds') && !l.startsWith('#'),
      );
      final value = double.parse(valueLine.split(' ').last);
      // Should be within 5 seconds of now
      final now = DateTime.now().millisecondsSinceEpoch / 1000;
      expect(value, closeTo(now, 5.0));
    });

    // ── Counter registration ──

    test('createCounter() returns a Counter', () {
      final counter = registry.createCounter(
        name: 'test_total',
        help: 'A test counter',
      );
      expect(counter, isA<Counter>());
      expect(counter.name, equals('test_total'));
    });

    test('createCounter() rejects duplicate name', () {
      registry.createCounter(name: 'dup', help: 'h');
      expect(
        () => registry.createCounter(name: 'dup', help: 'h'),
        throwsArgumentError,
      );
    });

    // ── Gauge registration ──

    test('createGauge() returns a Gauge', () {
      final gauge = registry.createGauge(name: 'test_gauge', help: 'A gauge');
      expect(gauge, isA<Gauge>());
      expect(gauge.name, equals('test_gauge'));
    });

    test('createGauge() rejects duplicate name', () {
      registry.createGauge(name: 'dup', help: 'h');
      expect(
        () => registry.createGauge(name: 'dup', help: 'h'),
        throwsArgumentError,
      );
    });

    // ── Histogram registration ──

    test('createHistogram() returns a Histogram', () {
      final hist = registry.createHistogram(
        name: 'test_hist',
        help: 'A histogram',
      );
      expect(hist, isA<Histogram>());
      expect(hist.name, equals('test_hist'));
    });

    test('createHistogram() with custom buckets', () {
      final hist = registry.createHistogram(
        name: 'custom_hist',
        help: 'h',
        buckets: [0.1, 1.0, 10.0],
      );
      expect(hist.buckets, equals([0.1, 1.0, 10.0]));
    });

    test('createHistogram() rejects duplicate name', () {
      registry.createHistogram(name: 'dup', help: 'h');
      expect(
        () => registry.createHistogram(name: 'dup', help: 'h'),
        throwsArgumentError,
      );
    });

    // ── Cross-type duplicate ──

    test('rejects duplicate name across different metric types', () {
      registry.createCounter(name: 'shared', help: 'h');
      expect(
        () => registry.createGauge(name: 'shared', help: 'h'),
        throwsArgumentError,
      );
    });

    // ── Serialization (Prometheus text format) ──

    group('serialize()', () {
      test('empty registry returns only process_start_time', () {
        final output = registry.serialize();
        expect(output, contains('process_start_time_seconds'));
        // No other HELP/TYPE lines
        final helpLines =
            output.split('\n').where((l) => l.startsWith('# HELP'));
        expect(helpLines, hasLength(1)); // only process_start_time_seconds
      });

      test('serializes counter with HELP, TYPE, and value lines', () {
        final counter = registry.createCounter(
          name: 'http_requests_total',
          help: 'Total HTTP requests',
        );
        counter.labels({'method': 'GET', 'status_code': '200'}).inc(42);

        final output = registry.serialize();
        expect(
          output,
          contains('# HELP http_requests_total Total HTTP requests'),
        );
        expect(output, contains('# TYPE http_requests_total counter'));
        expect(
          output,
          contains(
            'http_requests_total{method="GET",status_code="200"} 42',
          ),
        );
      });

      test('serializes gauge', () {
        final gauge = registry.createGauge(
          name: 'temperature',
          help: 'Current temperature',
        );
        gauge.labels({'location': 'office'}).set(22.5);

        final output = registry.serialize();
        expect(output, contains('# TYPE temperature gauge'));
        expect(output, contains('temperature{location="office"} 22.5'));
      });

      test('serializes histogram with buckets, count, sum', () {
        final hist = registry.createHistogram(
          name: 'request_duration',
          help: 'Duration',
          buckets: [0.1, 0.5, 1.0],
        );
        hist.labels({'method': 'GET'}).observe(0.3);

        final output = registry.serialize();
        expect(output, contains('# TYPE request_duration histogram'));
        expect(output,
            contains('request_duration_bucket{method="GET",le="0.1"} 0'));
        expect(output,
            contains('request_duration_bucket{method="GET",le="0.5"} 1'));
        expect(output,
            contains('request_duration_bucket{method="GET",le="1.0"} 1'));
        expect(output,
            contains('request_duration_bucket{method="GET",le="+Inf"} 1'));
        expect(output, contains('request_duration_count{method="GET"} 1'));
        expect(output, contains('request_duration_sum{method="GET"} 0.3'));
      });

      test('ends with newline', () {
        final output = registry.serialize();
        expect(output, endsWith('\n'));
      });

      test('separate metrics with blank line', () {
        registry.createCounter(name: 'a', help: 'ha');
        registry.createGauge(name: 'b', help: 'hb');

        final output = registry.serialize();
        // Between two metric blocks there should be a blank line
        expect(output, contains('\n\n'));
      });
    });
  });

  // ── MetricsRegistrar ──────────────────────────────────────────────────

  group('MetricsRegistrar', () {
    late MetricRegistry registry;
    late MetricsRegistrar registrar;

    setUp(() {
      registry = MetricRegistry();
      registrar = MetricsRegistrar(registry);
    });

    test('createCounter() validates name format', () {
      expect(
        () => registrar.createCounter(name: '', help: 'h'),
        throwsArgumentError,
      );
      expect(
        () => registrar.createCounter(name: '123bad', help: 'h'),
        throwsArgumentError,
      );
      expect(
        () => registrar.createCounter(name: 'has space', help: 'h'),
        throwsArgumentError,
      );
    });

    test('createCounter() accepts valid name', () {
      final counter = registrar.createCounter(
        name: 'my_app_requests_total',
        help: 'My counter',
      );
      expect(counter, isA<Counter>());
    });

    test('createGauge() validates name format', () {
      expect(
        () => registrar.createGauge(name: '', help: 'h'),
        throwsArgumentError,
      );
    });

    test('createGauge() accepts valid name', () {
      final gauge = registrar.createGauge(
        name: 'my_gauge',
        help: 'A gauge',
      );
      expect(gauge, isA<Gauge>());
    });

    test('createHistogram() validates name format', () {
      expect(
        () => registrar.createHistogram(name: '!invalid', help: 'h'),
        throwsArgumentError,
      );
    });

    test('createHistogram() accepts valid name and buckets', () {
      final hist = registrar.createHistogram(
        name: 'my_hist',
        help: 'A hist',
        buckets: [0.5, 1.0],
      );
      expect(hist, isA<Histogram>());
    });

    test('rejects names starting with reserved prefix', () {
      // Names starting with __ are reserved internally
      expect(
        () => registrar.createCounter(name: '__internal', help: 'h'),
        throwsArgumentError,
      );
    });

    test('custom metrics appear in registry serialization', () {
      registrar.createCounter(name: 'custom_total', help: 'Custom counter');
      final output = registry.serialize();
      expect(output, contains('# HELP custom_total Custom counter'));
    });
  });
}
