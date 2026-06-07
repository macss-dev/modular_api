import { describe, it, expect, beforeEach } from 'vitest';
import { MetricRegistry, MetricsRegistrar } from '../../src/core/metrics/metric_registry';

describe('MetricRegistry', () => {
  let registry: MetricRegistry;

  beforeEach(() => {
    registry = new MetricRegistry();
  });

  it('registers process_start_time_seconds on construction', () => {
    const output = registry.serialize();
    expect(output).toContain('process_start_time_seconds');
    expect(output).toContain('# TYPE process_start_time_seconds gauge');
  });

  it('process_start_time_seconds is set to epoch seconds', () => {
    const output = registry.serialize();
    const lines = output.split('\n');
    const valueLine = lines.find(
      (l) => l.startsWith('process_start_time_seconds') && !l.startsWith('#'),
    )!;
    const value = parseFloat(valueLine.split(' ')[1]);
    const now = Date.now() / 1000;
    expect(value).toBeCloseTo(now, 0); // within 1 second
  });

  // Counter

  it('createCounter() returns a counter', () => {
    const counter = registry.createCounter({ name: 'test_total', help: 'A test' });
    expect(counter).toBeDefined();
  });

  it('createCounter() rejects duplicate name', () => {
    registry.createCounter({ name: 'dup', help: 'h' });
    expect(() => registry.createCounter({ name: 'dup', help: 'h' })).toThrow();
  });

  // Gauge

  it('createGauge() returns a gauge', () => {
    const gauge = registry.createGauge({ name: 'test_gauge', help: 'A gauge' });
    expect(gauge).toBeDefined();
  });

  it('createGauge() rejects duplicate name', () => {
    registry.createGauge({ name: 'dup_g', help: 'h' });
    expect(() => registry.createGauge({ name: 'dup_g', help: 'h' })).toThrow();
  });

  // Histogram

  it('createHistogram() returns a histogram', () => {
    const hist = registry.createHistogram({ name: 'test_hist', help: 'A hist' });
    expect(hist).toBeDefined();
  });

  it('createHistogram() with custom buckets', () => {
    const hist = registry.createHistogram({
      name: 'custom_hist',
      help: 'h',
      buckets: [0.1, 1.0, 10.0],
    });
    expect(hist).toBeDefined();
  });

  it('createHistogram() rejects duplicate name', () => {
    registry.createHistogram({ name: 'dup_h', help: 'h' });
    expect(() => registry.createHistogram({ name: 'dup_h', help: 'h' })).toThrow();
  });

  // Cross-type duplicate

  it('rejects duplicate name across different metric types', () => {
    registry.createCounter({ name: 'shared', help: 'h' });
    expect(() => registry.createGauge({ name: 'shared', help: 'h' })).toThrow();
  });

  // Serialization

  describe('serialize()', () => {
    it('serializes counter with HELP, TYPE, and value', () => {
      const counter = registry.createCounter({
        name: 'http_requests_total',
        help: 'Total HTTP requests',
        labelNames: ['method', 'status_code'] as const,
      });
      counter.inc({ method: 'GET', status_code: '200' });

      const output = registry.serialize();
      expect(output).toContain('# HELP http_requests_total Total HTTP requests');
      expect(output).toContain('# TYPE http_requests_total counter');
      expect(output).toContain('method="GET"');
      expect(output).toContain('status_code="200"');
    });

    it('serializes gauge', () => {
      const gauge = registry.createGauge({
        name: 'temperature',
        help: 'Current temperature',
        labelNames: ['location'] as const,
      });
      gauge.set({ location: 'office' }, 22.5);

      const output = registry.serialize();
      expect(output).toContain('# TYPE temperature gauge');
      expect(output).toContain('location="office"');
      expect(output).toContain('22.5');
    });

    it('serializes histogram with buckets, count, sum', () => {
      const hist = registry.createHistogram({
        name: 'request_duration',
        help: 'Duration',
        labelNames: ['method'] as const,
        buckets: [0.1, 0.5, 1.0],
      });
      hist.observe({ method: 'GET' }, 0.3);

      const output = registry.serialize();
      expect(output).toContain('# TYPE request_duration histogram');
      expect(output).toContain('request_duration_bucket{method="GET",le="0.1"} 0');
      expect(output).toContain('request_duration_bucket{method="GET",le="0.5"} 1');
      expect(output).toContain('request_duration_bucket{method="GET",le="1.0"} 1');
      expect(output).toContain('request_duration_count{method="GET"} 1');
      expect(output).toContain('request_duration_sum{method="GET"} 0.3');
    });

    it('ends with newline', () => {
      const output = registry.serialize();
      expect(output).toMatch(/\n$/);
    });
  });
});

describe('MetricsRegistrar', () => {
  let registry: MetricRegistry;
  let registrar: MetricsRegistrar;

  beforeEach(() => {
    registry = new MetricRegistry();
    registrar = new MetricsRegistrar(registry);
  });

  it('createCounter() validates name format', () => {
    expect(() => registrar.createCounter({ name: '', help: 'h' })).toThrow();
    expect(() => registrar.createCounter({ name: '123bad', help: 'h' })).toThrow();
    expect(() => registrar.createCounter({ name: 'has space', help: 'h' })).toThrow();
  });

  it('createCounter() accepts valid name', () => {
    const counter = registrar.createCounter({
      name: 'my_app_requests_total',
      help: 'My counter',
    });
    expect(counter).toBeDefined();
  });

  it('createGauge() validates name format', () => {
    expect(() => registrar.createGauge({ name: '', help: 'h' })).toThrow();
  });

  it('createGauge() accepts valid name', () => {
    const gauge = registrar.createGauge({ name: 'my_gauge', help: 'A gauge' });
    expect(gauge).toBeDefined();
  });

  it('createHistogram() validates name format', () => {
    expect(() => registrar.createHistogram({ name: '!invalid', help: 'h' })).toThrow();
  });

  it('createHistogram() accepts valid name and buckets', () => {
    const hist = registrar.createHistogram({
      name: 'my_hist',
      help: 'A hist',
      buckets: [0.5, 1.0],
    });
    expect(hist).toBeDefined();
  });

  it('rejects names starting with reserved prefix __', () => {
    expect(() => registrar.createCounter({ name: '__internal', help: 'h' })).toThrow();
  });

  it('custom metrics appear in registry serialization', () => {
    registrar.createCounter({ name: 'custom_total', help: 'Custom counter' });
    const output = registry.serialize();
    expect(output).toContain('# HELP custom_total Custom counter');
  });
});
