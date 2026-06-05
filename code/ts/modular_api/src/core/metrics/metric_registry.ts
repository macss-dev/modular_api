// ============================================================
// core/metrics/metric_registry.ts
// Pure TypeScript metric registry — zero external dependencies.
//   MetricRegistry — internal, manages all metrics + serialization
//   MetricsRegistrar — public, validates names before delegating
// Mirror of metric_registry.dart and metric_registry.py.
// ============================================================

import { Counter, Gauge, Histogram } from './metric';
import type { MetricSample } from './metric';

/** Prometheus metric name regex. */
const VALID_NAME = /^[a-zA-Z_:][a-zA-Z0-9_:]*$/;

function assertValidName(name: string): void {
  if (!name || !VALID_NAME.test(name)) {
    throw new Error(`Invalid metric name "${name}": must match [a-zA-Z_:][a-zA-Z0-9_:]*`);
  }
}

// ── Internal entry ────────────────────────────────────────────

interface MetricEntry {
  name: string;
  help: string;
  metric: Counter | Gauge | Histogram;
}

function metricType(m: Counter | Gauge | Histogram): string {
  return m.type;
}

// ── MetricRegistry (internal) ─────────────────────────────────

/**
 * Internal registry that holds all metrics and serializes them.
 *
 * On construction, registers `process_start_time_seconds` as a gauge
 * set to the current epoch in seconds.
 */
export class MetricRegistry {
  private readonly _metrics: MetricEntry[] = [];
  private readonly _names = new Set<string>();

  constructor() {
    const gauge = this.createGauge({
      name: 'process_start_time_seconds',
      help: 'Start time of the process since unix epoch in seconds.',
    });
    gauge.set(Date.now() / 1000);
  }

  createCounter(config: { name: string; help: string; labelNames?: readonly string[] }): Counter {
    this.assertUnique(config.name);
    const counter = new Counter({ name: config.name, help: config.help });
    this._metrics.push({ name: config.name, help: config.help, metric: counter });
    return counter;
  }

  createGauge(config: { name: string; help: string; labelNames?: readonly string[] }): Gauge {
    this.assertUnique(config.name);
    const gauge = new Gauge({ name: config.name, help: config.help });
    this._metrics.push({ name: config.name, help: config.help, metric: gauge });
    return gauge;
  }

  createHistogram(config: {
    name: string;
    help: string;
    labelNames?: readonly string[];
    buckets?: number[];
  }): Histogram {
    this.assertUnique(config.name);
    const histogram = new Histogram({
      name: config.name,
      help: config.help,
      buckets: config.buckets,
    });
    this._metrics.push({ name: config.name, help: config.help, metric: histogram });
    return histogram;
  }

  /** Serializes all metrics to Prometheus text exposition format. */
  serialize(): string {
    const lines: string[] = [];

    for (let i = 0; i < this._metrics.length; i++) {
      const entry = this._metrics[i];

      // Blank line between metric families (not before the first one).
      if (i > 0) lines.push('');

      lines.push(`# HELP ${entry.name} ${entry.help}`);
      lines.push(`# TYPE ${entry.name} ${metricType(entry.metric)}`);

      const metric = entry.metric;

      if (metric instanceof Counter) {
        this.serializeCounter(lines, metric);
      } else if (metric instanceof Gauge) {
        this.serializeGauge(lines, metric);
      } else if (metric instanceof Histogram) {
        this.serializeHistogram(lines, metric);
      }
    }

    return lines.join('\n') + '\n';
  }

  private serializeCounter(lines: string[], counter: Counter): void {
    const samples = counter.collect();
    if (samples.length === 0) return;
    for (const s of samples) {
      lines.push(`${counter.name}${formatLabels(s.labels)} ${formatValue(s.value)}`);
    }
  }

  private serializeGauge(lines: string[], gauge: Gauge): void {
    const samples = gauge.collect();
    if (samples.length === 0) {
      // Root gauge with no labeled children — emit the root value.
      lines.push(`${gauge.name} ${formatValue(gauge.value)}`);
    } else {
      for (const s of samples) {
        lines.push(`${gauge.name}${formatLabels(s.labels)} ${formatValue(s.value)}`);
      }
    }
  }

  private serializeHistogram(lines: string[], histogram: Histogram): void {
    const samples = histogram.collect();
    if (samples.length === 0) return;
    for (const s of samples) {
      lines.push(
        `${histogram.name}${s.suffix}${formatLabels(s.labels)} ${formatValue(s.value)}`,
      );
    }
  }

  private assertUnique(name: string): void {
    if (this._names.has(name)) {
      throw new Error(`Metric "${name}" is already registered.`);
    }
    this._names.add(name);
  }
}

// ── Serialization helpers ─────────────────────────────────────

function formatLabels(labels: Record<string, string>): string {
  const keys = Object.keys(labels);
  if (keys.length === 0) return '';
  const pairs = keys.map((k) => `${k}="${labels[k]}"`).join(',');
  return `{${pairs}}`;
}

function formatValue(v: number): string {
  if (Number.isInteger(v)) return String(v);
  return String(v);
}

// ── MetricsRegistrar (public) ─────────────────────────────────

/**
 * Public API for users to register custom metrics.
 * Validates names and rejects reserved prefixes before delegating.
 */
export class MetricsRegistrar {
  constructor(private readonly registry: MetricRegistry) {}

  createCounter(config: { name: string; help: string; labelNames?: readonly string[] }): Counter {
    this.validate(config.name);
    return this.registry.createCounter(config);
  }

  createGauge(config: { name: string; help: string; labelNames?: readonly string[] }): Gauge {
    this.validate(config.name);
    return this.registry.createGauge(config);
  }

  createHistogram(config: {
    name: string;
    help: string;
    labelNames?: readonly string[];
    buckets?: number[];
  }): Histogram {
    this.validate(config.name);
    return this.registry.createHistogram(config);
  }

  private validate(name: string): void {
    assertValidName(name);
    if (name.startsWith('__')) {
      throw new Error(`Metric name "${name}" uses reserved prefix "__".`);
    }
  }
}
