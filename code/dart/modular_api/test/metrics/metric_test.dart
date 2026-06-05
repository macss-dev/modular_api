import 'package:test/test.dart';
import 'package:modular_api/src/core/metrics/metric.dart';

void main() {
  // ── Counter ────────────────────────────────────────────────────────────

  group('Counter', () {
    test('starts at zero', () {
      final counter =
          Counter(name: 'http_requests_total', help: 'Total requests');
      expect(counter.value, equals(0.0));
    });

    test('inc() increments by 1', () {
      final counter = Counter(name: 'c', help: 'h');
      counter.inc();
      expect(counter.value, equals(1.0));
    });

    test('inc() with custom amount', () {
      final counter = Counter(name: 'c', help: 'h');
      counter.inc(5);
      expect(counter.value, equals(5.0));
    });

    test('inc() accumulates', () {
      final counter = Counter(name: 'c', help: 'h');
      counter.inc(3);
      counter.inc(2);
      expect(counter.value, equals(5.0));
    });

    test('inc() throws on negative amount', () {
      final counter = Counter(name: 'c', help: 'h');
      expect(() => counter.inc(-1), throwsArgumentError);
    });

    test('inc() throws on zero amount', () {
      final counter = Counter(name: 'c', help: 'h');
      expect(() => counter.inc(0), throwsArgumentError);
    });

    test('labels() returns child with labels', () {
      final counter = Counter(name: 'http_requests_total', help: 'h');
      final child = counter.labels({'method': 'GET', 'status_code': '200'});
      child.inc();
      expect(child.value, equals(1.0));
    });

    test('labels() returns same child for same label set', () {
      final counter = Counter(name: 'c', help: 'h');
      final a = counter.labels({'method': 'GET'});
      final b = counter.labels({'method': 'GET'});
      a.inc();
      expect(b.value, equals(1.0));
    });

    test('labels() returns different children for different label sets', () {
      final counter = Counter(name: 'c', help: 'h');
      final get = counter.labels({'method': 'GET'});
      final post = counter.labels({'method': 'POST'});
      get.inc(3);
      post.inc(1);
      expect(get.value, equals(3.0));
      expect(post.value, equals(1.0));
    });

    test('exposes name and help', () {
      final counter = Counter(name: 'my_counter', help: 'A counter');
      expect(counter.name, equals('my_counter'));
      expect(counter.help, equals('A counter'));
    });

    test('type is counter', () {
      final counter = Counter(name: 'c', help: 'h');
      expect(counter.type, equals('counter'));
    });

    test('collect() returns all label combinations', () {
      final counter = Counter(name: 'req', help: 'h');
      counter.labels({'method': 'GET'}).inc(10);
      counter.labels({'method': 'POST'}).inc(5);

      final samples = counter.collect();
      expect(samples, hasLength(2));
    });
  });

  // ── Gauge ──────────────────────────────────────────────────────────────

  group('Gauge', () {
    test('starts at zero', () {
      final gauge = Gauge(name: 'in_flight', help: 'Concurrent requests');
      expect(gauge.value, equals(0.0));
    });

    test('set() sets value', () {
      final gauge = Gauge(name: 'g', help: 'h');
      gauge.set(42);
      expect(gauge.value, equals(42.0));
    });

    test('set() overwrites previous value', () {
      final gauge = Gauge(name: 'g', help: 'h');
      gauge.set(10);
      gauge.set(20);
      expect(gauge.value, equals(20.0));
    });

    test('inc() increments by 1', () {
      final gauge = Gauge(name: 'g', help: 'h');
      gauge.inc();
      expect(gauge.value, equals(1.0));
    });

    test('inc() with custom amount', () {
      final gauge = Gauge(name: 'g', help: 'h');
      gauge.inc(5);
      expect(gauge.value, equals(5.0));
    });

    test('dec() decrements by 1', () {
      final gauge = Gauge(name: 'g', help: 'h');
      gauge.set(5);
      gauge.dec();
      expect(gauge.value, equals(4.0));
    });

    test('dec() with custom amount', () {
      final gauge = Gauge(name: 'g', help: 'h');
      gauge.set(10);
      gauge.dec(3);
      expect(gauge.value, equals(7.0));
    });

    test('can go negative', () {
      final gauge = Gauge(name: 'g', help: 'h');
      gauge.dec(5);
      expect(gauge.value, equals(-5.0));
    });

    test('labels() returns child with labels', () {
      final gauge = Gauge(name: 'g', help: 'h');
      final child = gauge.labels({'route': '/api/test'});
      child.set(99);
      expect(child.value, equals(99.0));
    });

    test('labels() returns same child for same label set', () {
      final gauge = Gauge(name: 'g', help: 'h');
      final a = gauge.labels({'k': 'v'});
      final b = gauge.labels({'k': 'v'});
      a.set(42);
      expect(b.value, equals(42.0));
    });

    test('type is gauge', () {
      final gauge = Gauge(name: 'g', help: 'h');
      expect(gauge.type, equals('gauge'));
    });

    test('collect() returns all label combinations', () {
      final gauge = Gauge(name: 'g', help: 'h');
      gauge.labels({'a': '1'}).set(10);
      gauge.labels({'a': '2'}).set(20);

      final samples = gauge.collect();
      expect(samples, hasLength(2));
    });
  });

  // ── Histogram ──────────────────────────────────────────────────────────

  group('Histogram', () {
    final defaultBuckets = [
      0.005,
      0.01,
      0.025,
      0.05,
      0.1,
      0.25,
      0.5,
      1.0,
      2.5,
      5.0,
      10.0,
    ];

    test('uses default buckets when none provided', () {
      final hist = Histogram(
        name: 'http_request_duration_seconds',
        help: 'Duration',
      );
      expect(hist.buckets, equals(defaultBuckets));
    });

    test('accepts custom buckets', () {
      final hist = Histogram(
        name: 'h',
        help: 'h',
        buckets: [0.1, 0.5, 1.0],
      );
      expect(hist.buckets, equals([0.1, 0.5, 1.0]));
    });

    test('throws on empty buckets', () {
      expect(
        () => Histogram(name: 'h', help: 'h', buckets: []),
        throwsArgumentError,
      );
    });

    test('throws on unsorted buckets', () {
      expect(
        () => Histogram(name: 'h', help: 'h', buckets: [1.0, 0.5]),
        throwsArgumentError,
      );
    });

    test('observe() records value in correct buckets', () {
      final hist = Histogram(
        name: 'h',
        help: 'h',
        buckets: [0.1, 0.5, 1.0],
      );
      hist.observe(0.3);

      final samples = hist.collect();
      // Should have bucket lines for 0.1, 0.5, 1.0, +Inf, plus _sum and _count
      // bucket(0.1) = 0  (0.3 > 0.1)
      // bucket(0.5) = 1  (0.3 <= 0.5)
      // bucket(1.0) = 1  (0.3 <= 1.0)
      // bucket(+Inf) = 1
      // _count = 1
      // _sum = 0.3
      final bucketSamples =
          samples.where((s) => s.suffix == '_bucket').toList();
      expect(bucketSamples, hasLength(4)); // 3 buckets + Inf

      // le=0.1 → 0
      expect(
        bucketSamples.firstWhere((s) => s.labels['le'] == '0.1').value,
        equals(0.0),
      );
      // le=0.5 → 1
      expect(
        bucketSamples.firstWhere((s) => s.labels['le'] == '0.5').value,
        equals(1.0),
      );
      // le=1.0 → 1
      expect(
        bucketSamples.firstWhere((s) => s.labels['le'] == '1.0').value,
        equals(1.0),
      );
      // le=+Inf → 1
      expect(
        bucketSamples.firstWhere((s) => s.labels['le'] == '+Inf').value,
        equals(1.0),
      );
    });

    test('observe() accumulates count and sum', () {
      final hist = Histogram(
        name: 'h',
        help: 'h',
        buckets: [1.0],
      );
      hist.observe(0.5);
      hist.observe(0.8);

      final samples = hist.collect();
      final count = samples.firstWhere((s) => s.suffix == '_count').value;
      final sum = samples.firstWhere((s) => s.suffix == '_sum').value;
      expect(count, equals(2.0));
      expect(sum, equals(1.3));
    });

    test('observe() throws on negative value', () {
      final hist = Histogram(name: 'h', help: 'h');
      expect(() => hist.observe(-1), throwsArgumentError);
    });

    test('labels() returns child histogram', () {
      final hist = Histogram(
        name: 'h',
        help: 'h',
        buckets: [1.0],
      );
      final child = hist.labels({'method': 'GET'});
      child.observe(0.5);

      final samples = hist.collect();
      final countSamples = samples.where((s) => s.suffix == '_count').toList();
      expect(countSamples, hasLength(1));
      expect(countSamples.first.labels['method'], equals('GET'));
    });

    test('labels() returns same child for same label set', () {
      final hist = Histogram(
        name: 'h',
        help: 'h',
        buckets: [1.0],
      );
      final a = hist.labels({'m': 'GET'});
      final b = hist.labels({'m': 'GET'});
      a.observe(0.5);
      b.observe(1.0);

      final samples = hist.collect();
      final count = samples.firstWhere((s) => s.suffix == '_count').value;
      expect(count, equals(2.0));
    });

    test('type is histogram', () {
      final hist = Histogram(name: 'h', help: 'h');
      expect(hist.type, equals('histogram'));
    });

    test('collect() with no observations returns empty', () {
      final hist = Histogram(name: 'h', help: 'h');
      expect(hist.collect(), isEmpty);
    });
  });

  // ── MetricSample ───────────────────────────────────────────────────────

  group('MetricSample', () {
    test('holds name, labels, value, suffix', () {
      final sample = MetricSample(
        name: 'http_requests_total',
        labels: {'method': 'GET', 'status_code': '200'},
        value: 42,
        suffix: '',
      );
      expect(sample.name, equals('http_requests_total'));
      expect(sample.labels, equals({'method': 'GET', 'status_code': '200'}));
      expect(sample.value, equals(42.0));
      expect(sample.suffix, equals(''));
    });
  });
}
