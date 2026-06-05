/// Prometheus-compatible metric types: Counter, Gauge, Histogram.
///
/// Zero external dependencies — pure Dart implementation.
library;

// ── MetricSample ─────────────────────────────────────────────────────────

/// A single data point collected from a metric.
class MetricSample {
  final String name;
  final Map<String, String> labels;
  final double value;

  /// Optional suffix such as `_bucket`, `_count`, `_sum`.
  final String suffix;

  MetricSample({
    required this.name,
    required this.labels,
    required num value,
    required this.suffix,
  }) : value = value.toDouble();
}

// ── Shared helpers ───────────────────────────────────────────────────────

/// Canonical key for a label set so we can reuse children.
String _labelKey(Map<String, String> labels) {
  final sorted = labels.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return sorted.map((e) => '${e.key}=${e.value}').join(',');
}

// ── Counter ──────────────────────────────────────────────────────────────

/// Monotonically increasing counter (Prometheus COUNTER type).
class Counter {
  final String name;
  final String help;
  String get type => 'counter';

  double _value = 0;
  double get value => _value;

  /// Labeled children keyed by canonical label string.
  final Map<String, LabeledCounter> _children = {};

  Counter({required this.name, required this.help});

  /// Increments by [amount] (must be > 0).
  void inc([num amount = 1]) {
    if (amount <= 0) {
      throw ArgumentError.value(amount, 'amount', 'must be positive');
    }
    _value += amount;
  }

  /// Returns (or creates) a child counter for the given [labelValues].
  LabeledCounter labels(Map<String, String> labelValues) {
    final key = _labelKey(labelValues);
    return _children.putIfAbsent(
      key,
      () => LabeledCounter._(Map.unmodifiable(labelValues)),
    );
  }

  /// Collects samples from all labeled children.
  List<MetricSample> collect() {
    return _children.entries.map((e) {
      return MetricSample(
        name: name,
        labels: e.value._labels,
        value: e.value.value,
        suffix: '',
      );
    }).toList();
  }
}

/// Labeled counter child — holds a value for a specific label combination.
class LabeledCounter {
  final Map<String, String> _labels;
  double _value = 0;
  double get value => _value;

  LabeledCounter._(this._labels);

  void inc([num amount = 1]) {
    if (amount <= 0) {
      throw ArgumentError.value(amount, 'amount', 'must be positive');
    }
    _value += amount;
  }
}

// ── Gauge ────────────────────────────────────────────────────────────────

/// Value that can go up and down (Prometheus GAUGE type).
class Gauge {
  final String name;
  final String help;
  String get type => 'gauge';

  double _value = 0;
  double get value => _value;

  final Map<String, LabeledGauge> _children = {};

  Gauge({required this.name, required this.help});

  void set(num v) => _value = v.toDouble();
  void inc([num amount = 1]) => _value += amount;
  void dec([num amount = 1]) => _value -= amount;

  LabeledGauge labels(Map<String, String> labelValues) {
    final key = _labelKey(labelValues);
    return _children.putIfAbsent(
      key,
      () => LabeledGauge._(Map.unmodifiable(labelValues)),
    );
  }

  List<MetricSample> collect() {
    return _children.entries.map((e) {
      return MetricSample(
        name: name,
        labels: e.value._labels,
        value: e.value.value,
        suffix: '',
      );
    }).toList();
  }
}

/// Labeled gauge child — holds a value for a specific label combination.
class LabeledGauge {
  final Map<String, String> _labels;
  double _value = 0;
  double get value => _value;

  LabeledGauge._(this._labels);

  void set(num v) => _value = v.toDouble();
  void inc([num amount = 1]) => _value += amount;
  void dec([num amount = 1]) => _value -= amount;
}

// ── Histogram ────────────────────────────────────────────────────────────

/// Default Prometheus histogram buckets.
const List<double> defaultBuckets = [
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

/// Records observations in pre-defined buckets (Prometheus HISTOGRAM type).
class Histogram {
  final String name;
  final String help;
  final List<double> buckets;
  String get type => 'histogram';

  final Map<String, LabeledHistogram> _children = {};

  Histogram({
    required this.name,
    required this.help,
    List<double>? buckets,
  }) : buckets = buckets ?? List.unmodifiable(defaultBuckets) {
    _validateBuckets(this.buckets);
  }

  /// Observe a [value] (must be >= 0).
  void observe(num value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'must be non-negative');
    }
    // Observation without labels — create a "root" child with empty labels.
    labels({}).observe(value);
  }

  LabeledHistogram labels(Map<String, String> labelValues) {
    final key = _labelKey(labelValues);
    return _children.putIfAbsent(
      key,
      () => LabeledHistogram._(Map.unmodifiable(labelValues), buckets),
    );
  }

  /// Collects all samples across all label combinations.
  List<MetricSample> collect() {
    final samples = <MetricSample>[];
    for (final child in _children.values) {
      samples.addAll(child.collect(name));
    }
    return samples;
  }

  static void _validateBuckets(List<double> b) {
    if (b.isEmpty) {
      throw ArgumentError('buckets must not be empty');
    }
    for (var i = 1; i < b.length; i++) {
      if (b[i] <= b[i - 1]) {
        throw ArgumentError('buckets must be sorted in increasing order');
      }
    }
  }
}

/// Labeled histogram child — holds buckets for a specific label combination.
class LabeledHistogram {
  final Map<String, String> _labels;
  final List<double> _boundaries;

  /// Cumulative counts for each bucket boundary + one for +Inf.
  late final List<int> _cumulativeCounts;
  double _sum = 0;
  int _count = 0;

  LabeledHistogram._(this._labels, this._boundaries) {
    _cumulativeCounts = List.filled(_boundaries.length + 1, 0);
  }

  void observe(num value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'must be non-negative');
    }
    _count++;
    _sum += value.toDouble();

    // Update cumulative counts: every bucket where value <= boundary gets +1.
    for (var i = 0; i < _boundaries.length; i++) {
      if (value <= _boundaries[i]) {
        _cumulativeCounts[i]++;
      }
    }
    // +Inf bucket always gets +1.
    _cumulativeCounts[_boundaries.length]++;
  }

  List<MetricSample> collect(String metricName) {
    final samples = <MetricSample>[];

    // Bucket samples
    for (var i = 0; i < _boundaries.length; i++) {
      samples.add(MetricSample(
        name: metricName,
        labels: {..._labels, 'le': _formatBucket(_boundaries[i])},
        value: _cumulativeCounts[i],
        suffix: '_bucket',
      ));
    }
    // +Inf bucket
    samples.add(MetricSample(
      name: metricName,
      labels: {..._labels, 'le': '+Inf'},
      value: _cumulativeCounts[_boundaries.length],
      suffix: '_bucket',
    ));

    // _count
    samples.add(MetricSample(
      name: metricName,
      labels: _labels,
      value: _count,
      suffix: '_count',
    ));

    // _sum
    samples.add(MetricSample(
      name: metricName,
      labels: _labels,
      value: _sum,
      suffix: '_sum',
    ));

    return samples;
  }

  /// Formats bucket boundary for Prometheus (no trailing zeros except ".0").
  String _formatBucket(double v) {
    // If it's an integer value, return with one decimal
    if (v == v.truncateToDouble()) {
      return v.toStringAsFixed(1);
    }
    return v.toString();
  }
}
