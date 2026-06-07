/// Internal metric registry and public registrar for custom metrics.
///
/// [MetricRegistry] — stores all metrics, serializes to Prometheus text format.
/// [MetricsRegistrar] — public API that validates names before delegating.
library;

import 'metric.dart';

// ── Prometheus name validation ───────────────────────────────────────────

final _validName = RegExp(r'^[a-zA-Z_:][a-zA-Z0-9_:]*$');

/// Validates a Prometheus metric name.
void _assertValidName(String name) {
  if (name.isEmpty || !_validName.hasMatch(name)) {
    throw ArgumentError.value(
      name,
      'name',
      'must match [a-zA-Z_:][a-zA-Z0-9_:]*',
    );
  }
}

// ── MetricRegistry (internal) ────────────────────────────────────────────

/// Internal registry that holds all metrics and serializes them.
class MetricRegistry {
  /// Ordered list of registered metrics (preserves insertion order).
  final List<_MetricEntry> _metrics = [];

  /// Set of registered names for duplicate detection.
  final Set<String> _names = {};

  MetricRegistry() {
    // Register process_start_time_seconds on construction.
    final gauge = createGauge(
      name: 'process_start_time_seconds',
      help: 'Start time of the process since unix epoch in seconds.',
    );
    gauge.set(DateTime.now().millisecondsSinceEpoch / 1000);
  }

  // ── Factory methods ──

  Counter createCounter({required String name, required String help}) {
    _assertUnique(name);
    final counter = Counter(name: name, help: help);
    _metrics.add(_MetricEntry(name: name, help: help, metric: counter));
    return counter;
  }

  Gauge createGauge({required String name, required String help}) {
    _assertUnique(name);
    final gauge = Gauge(name: name, help: help);
    _metrics.add(_MetricEntry(name: name, help: help, metric: gauge));
    return gauge;
  }

  Histogram createHistogram({
    required String name,
    required String help,
    List<double>? buckets,
  }) {
    _assertUnique(name);
    final hist = Histogram(name: name, help: help, buckets: buckets);
    _metrics.add(_MetricEntry(name: name, help: help, metric: hist));
    return hist;
  }

  void _assertUnique(String name) {
    if (_names.contains(name)) {
      throw ArgumentError.value(name, 'name', 'metric already registered');
    }
    _names.add(name);
  }

  // ── Serialization ──

  /// Serializes all registered metrics to Prometheus text exposition format.
  String serialize() {
    final buf = StringBuffer();

    for (var i = 0; i < _metrics.length; i++) {
      final entry = _metrics[i];

      // Blank line between metric families (not before the first one).
      if (i > 0) buf.writeln();

      buf.writeln('# HELP ${entry.name} ${entry.help}');
      buf.writeln('# TYPE ${entry.name} ${entry.type}');

      final metric = entry.metric;

      if (metric is Counter) {
        _serializeCounter(buf, metric);
      } else if (metric is Gauge) {
        _serializeGauge(buf, metric);
      } else if (metric is Histogram) {
        _serializeHistogram(buf, metric);
      }
    }

    return buf.toString();
  }

  void _serializeCounter(StringBuffer buf, Counter counter) {
    final samples = counter.collect();
    if (samples.isEmpty) return;
    for (final s in samples) {
      buf.writeln(
          '${counter.name}${_formatLabels(s.labels)} ${_formatValue(s.value)}');
    }
  }

  void _serializeGauge(StringBuffer buf, Gauge gauge) {
    final samples = gauge.collect();
    if (samples.isEmpty) {
      // Root gauge with no labeled children — emit the root value.
      buf.writeln('${gauge.name} ${_formatValue(gauge.value)}');
    } else {
      for (final s in samples) {
        buf.writeln(
            '${gauge.name}${_formatLabels(s.labels)} ${_formatValue(s.value)}');
      }
    }
  }

  void _serializeHistogram(StringBuffer buf, Histogram histogram) {
    final samples = histogram.collect();
    if (samples.isEmpty) return;
    for (final s in samples) {
      buf.writeln(
        '${histogram.name}${s.suffix}${_formatLabels(s.labels)} ${_formatValue(s.value)}',
      );
    }
  }

  String _formatLabels(Map<String, String> labels) {
    if (labels.isEmpty) return '';
    final pairs = labels.entries.map((e) => '${e.key}="${e.value}"').join(',');
    return '{$pairs}';
  }

  String _formatValue(double v) {
    // Integers → no decimal; otherwise standard double.
    if (v == v.truncateToDouble()) {
      return v.toInt().toString();
    }
    return v.toString();
  }
}

class _MetricEntry {
  final String name;
  final String help;
  final dynamic metric;

  String get type {
    if (metric is Counter) return 'counter';
    if (metric is Gauge) return 'gauge';
    if (metric is Histogram) return 'histogram';
    return 'untyped';
  }

  _MetricEntry({
    required this.name,
    required this.help,
    required this.metric,
  });
}

// ── MetricsRegistrar (public) ────────────────────────────────────────────

/// Public API for users to register custom metrics.
///
/// Validates metric names and delegates to the internal [MetricRegistry].
class MetricsRegistrar {
  final MetricRegistry _registry;

  MetricsRegistrar(this._registry);

  Counter createCounter({required String name, required String help}) {
    _validate(name);
    return _registry.createCounter(name: name, help: help);
  }

  Gauge createGauge({required String name, required String help}) {
    _validate(name);
    return _registry.createGauge(name: name, help: help);
  }

  Histogram createHistogram({
    required String name,
    required String help,
    List<double>? buckets,
  }) {
    _validate(name);
    return _registry.createHistogram(name: name, help: help, buckets: buckets);
  }

  void _validate(String name) {
    _assertValidName(name);
    if (name.startsWith('__')) {
      throw ArgumentError.value(
        name,
        'name',
        'names starting with __ are reserved',
      );
    }
  }
}
