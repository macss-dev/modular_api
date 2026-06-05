// ============================================================
// core/metrics/metric.ts
// Prometheus-compatible metric types: Counter, Gauge, Histogram.
// Zero external dependencies — pure TypeScript implementation.
// Mirror of metric.dart and metric.py.
// ============================================================

// ── MetricSample ─────────────────────────────────────────────

/** A single data point collected from a metric. */
export interface MetricSample {
  readonly name: string;
  readonly labels: Record<string, string>;
  readonly value: number;
  /** Optional suffix such as `_bucket`, `_count`, `_sum`. */
  readonly suffix: string;
}

// ── Shared helpers ───────────────────────────────────────────

/** Canonical key for a label set so we can reuse children. */
function labelKey(labels: Record<string, string>): string {
  return Object.keys(labels)
    .sort()
    .map((k) => `${k}=${labels[k]}`)
    .join(',');
}

// ── Counter ──────────────────────────────────────────────────

/** Labeled counter child — holds a value for a specific label combination. */
export class LabeledCounter {
  private _value = 0;

  constructor(readonly labels: Readonly<Record<string, string>>) {}

  get value(): number {
    return this._value;
  }

  /** Increments by `amount` (must be > 0). */
  inc(amount = 1): void {
    if (amount <= 0) {
      throw new Error(`Counter increment must be positive, got ${amount}`);
    }
    this._value += amount;
  }
}

/** Monotonically increasing counter (Prometheus COUNTER type). */
export class Counter {
  readonly name: string;
  readonly help: string;
  readonly type = 'counter' as const;

  private _value = 0;
  private readonly _children = new Map<string, LabeledCounter>();

  constructor(opts: { name: string; help: string }) {
    this.name = opts.name;
    this.help = opts.help;
  }

  get value(): number {
    return this._value;
  }

  /** Increments by `amount` (must be > 0). */
  inc(amount?: number): void;
  inc(labels: Record<string, string>, amount?: number): void;
  inc(labelsOrAmount?: Record<string, string> | number, amount?: number): void {
    if (labelsOrAmount === undefined || typeof labelsOrAmount === 'number') {
      // inc() or inc(amount)
      const a = labelsOrAmount ?? 1;
      if (a <= 0) throw new Error(`Counter increment must be positive, got ${a}`);
      this._value += a;
    } else {
      // inc(labels) or inc(labels, amount)
      this.labels(labelsOrAmount).inc(amount ?? 1);
    }
  }

  /** Returns (or creates) a child counter for the given label values. */
  labels(labelValues: Record<string, string>): LabeledCounter {
    const key = labelKey(labelValues);
    let child = this._children.get(key);
    if (!child) {
      child = new LabeledCounter(Object.freeze({ ...labelValues }));
      this._children.set(key, child);
    }
    return child;
  }

  /** Collects samples from all labeled children. */
  collect(): MetricSample[] {
    return Array.from(this._children.values()).map((child) => ({
      name: this.name,
      labels: child.labels,
      value: child.value,
      suffix: '',
    }));
  }
}

// ── Gauge ────────────────────────────────────────────────────

/** Labeled gauge child — holds a value for a specific label combination. */
export class LabeledGauge {
  private _value = 0;

  constructor(readonly labels: Readonly<Record<string, string>>) {}

  get value(): number {
    return this._value;
  }

  set(v: number): void {
    this._value = v;
  }
  inc(amount = 1): void {
    this._value += amount;
  }
  dec(amount = 1): void {
    this._value -= amount;
  }
}

/** Value that can go up and down (Prometheus GAUGE type). */
export class Gauge {
  readonly name: string;
  readonly help: string;
  readonly type = 'gauge' as const;

  private _value = 0;
  private readonly _children = new Map<string, LabeledGauge>();

  constructor(opts: { name: string; help: string }) {
    this.name = opts.name;
    this.help = opts.help;
  }

  get value(): number {
    return this._value;
  }

  set(v: number): void;
  set(labels: Record<string, string>, v: number): void;
  set(labelsOrValue: Record<string, string> | number, v?: number): void {
    if (typeof labelsOrValue === 'number') {
      this._value = labelsOrValue;
    } else {
      this.labels(labelsOrValue).set(v!);
    }
  }

  inc(amount?: number): void;
  inc(labels: Record<string, string>, amount?: number): void;
  inc(labelsOrAmount?: Record<string, string> | number, amount?: number): void {
    if (labelsOrAmount === undefined || typeof labelsOrAmount === 'number') {
      this._value += labelsOrAmount ?? 1;
    } else {
      this.labels(labelsOrAmount).inc(amount ?? 1);
    }
  }

  dec(amount?: number): void;
  dec(labels: Record<string, string>, amount?: number): void;
  dec(labelsOrAmount?: Record<string, string> | number, amount?: number): void {
    if (labelsOrAmount === undefined || typeof labelsOrAmount === 'number') {
      this._value -= labelsOrAmount ?? 1;
    } else {
      this.labels(labelsOrAmount).dec(amount ?? 1);
    }
  }

  labels(labelValues: Record<string, string>): LabeledGauge {
    const key = labelKey(labelValues);
    let child = this._children.get(key);
    if (!child) {
      child = new LabeledGauge(Object.freeze({ ...labelValues }));
      this._children.set(key, child);
    }
    return child;
  }

  collect(): MetricSample[] {
    return Array.from(this._children.values()).map((child) => ({
      name: this.name,
      labels: child.labels,
      value: child.value,
      suffix: '',
    }));
  }
}

// ── Histogram ────────────────────────────────────────────────

/** Default Prometheus histogram buckets. */
export const DEFAULT_BUCKETS: readonly number[] = [
  0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0,
];

/** Formats bucket boundary for Prometheus (no trailing zeros except ".0"). */
function formatBucket(v: number): string {
  if (Number.isInteger(v)) return v.toFixed(1);
  return String(v);
}

function validateBuckets(b: readonly number[]): void {
  if (b.length === 0) throw new Error('buckets must not be empty');
  for (let i = 1; i < b.length; i++) {
    if (b[i] <= b[i - 1]) {
      throw new Error('buckets must be sorted in increasing order');
    }
  }
}

/** Labeled histogram child — holds buckets for a specific label combination. */
export class LabeledHistogram {
  private readonly _boundaries: readonly number[];
  private readonly _cumulativeCounts: number[];
  private _sum = 0;
  private _count = 0;

  constructor(
    readonly labels: Readonly<Record<string, string>>,
    boundaries: readonly number[],
  ) {
    this._boundaries = boundaries;
    this._cumulativeCounts = new Array(boundaries.length + 1).fill(0);
  }

  observe(value: number): void {
    if (value < 0) throw new Error(`Histogram value must be non-negative, got ${value}`);
    this._count++;
    this._sum += value;

    for (let i = 0; i < this._boundaries.length; i++) {
      if (value <= this._boundaries[i]) {
        this._cumulativeCounts[i]++;
      }
    }
    // +Inf bucket always gets +1
    this._cumulativeCounts[this._boundaries.length]++;
  }

  collect(metricName: string): MetricSample[] {
    const samples: MetricSample[] = [];

    for (let i = 0; i < this._boundaries.length; i++) {
      samples.push({
        name: metricName,
        labels: { ...this.labels, le: formatBucket(this._boundaries[i]) },
        value: this._cumulativeCounts[i],
        suffix: '_bucket',
      });
    }
    // +Inf bucket
    samples.push({
      name: metricName,
      labels: { ...this.labels, le: '+Inf' },
      value: this._cumulativeCounts[this._boundaries.length],
      suffix: '_bucket',
    });
    // _count
    samples.push({
      name: metricName,
      labels: this.labels,
      value: this._count,
      suffix: '_count',
    });
    // _sum
    samples.push({
      name: metricName,
      labels: this.labels,
      value: this._sum,
      suffix: '_sum',
    });

    return samples;
  }
}

/** Records observations in pre-defined buckets (Prometheus HISTOGRAM type). */
export class Histogram {
  readonly name: string;
  readonly help: string;
  readonly buckets: readonly number[];
  readonly type = 'histogram' as const;

  private readonly _children = new Map<string, LabeledHistogram>();

  constructor(opts: { name: string; help: string; buckets?: number[] }) {
    this.name = opts.name;
    this.help = opts.help;
    this.buckets = opts.buckets ?? [...DEFAULT_BUCKETS];
    validateBuckets(this.buckets);
  }

  /** Observe a value (must be >= 0). */
  observe(value: number): void;
  observe(labels: Record<string, string>, value: number): void;
  observe(labelsOrValue: Record<string, string> | number, value?: number): void {
    if (typeof labelsOrValue === 'number') {
      this.labels({}).observe(labelsOrValue);
    } else {
      this.labels(labelsOrValue).observe(value!);
    }
  }

  labels(labelValues: Record<string, string>): LabeledHistogram {
    const key = labelKey(labelValues);
    let child = this._children.get(key);
    if (!child) {
      child = new LabeledHistogram(Object.freeze({ ...labelValues }), this.buckets);
      this._children.set(key, child);
    }
    return child;
  }

  /** Collects all samples across all label combinations. */
  collect(): MetricSample[] {
    const samples: MetricSample[] = [];
    for (const child of this._children.values()) {
      samples.push(...child.collect(this.name));
    }
    return samples;
  }
}
