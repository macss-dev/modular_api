import { describe, it, expect, beforeEach } from 'vitest';
import express from 'express';
import request from 'supertest';
import { MetricRegistry } from '../../src/core/metrics/metric_registry';
import { metricsMiddleware, metricsHandler } from '../../src/core/metrics/metrics_middleware';
import type { Counter, Gauge, Histogram } from '../../src/core/metrics/metric';

describe('metricsMiddleware', () => {
  let registry: MetricRegistry;
  let requestsTotal: Counter;
  let requestsInFlight: Gauge;
  let requestDuration: Histogram;

  beforeEach(() => {
    registry = new MetricRegistry();
    requestsTotal = registry.createCounter({
      name: 'http_requests_total',
      help: 'Total HTTP requests',
      labelNames: ['method', 'route', 'status_code'] as const,
    });
    requestsInFlight = registry.createGauge({
      name: 'http_requests_in_flight',
      help: 'Concurrent requests',
    });
    requestDuration = registry.createHistogram({
      name: 'http_request_duration_seconds',
      help: 'Request duration',
      labelNames: ['method', 'route', 'status_code'] as const,
    });
  });

  function createApp(opts?: { excludedRoutes?: string[]; registeredPaths?: string[] }) {
    const app = express();
    app.use(
      metricsMiddleware({
        requestsTotal,
        requestsInFlight,
        requestDuration,
        excludedRoutes: opts?.excludedRoutes ?? [],
        registeredPaths: opts?.registeredPaths ?? [],
      }),
    );
    app.get('/api/test', (_req, res) => res.json({ ok: true }));
    app.post('/api/test', (_req, res) => res.json({ ok: true }));
    app.get('/metrics', (_req, res) => res.send('metrics'));
    app.get('/health', (_req, res) => res.send('ok'));
    return app;
  }

  it('increments http_requests_total with correct labels', async () => {
    const app = createApp({ registeredPaths: ['/api/test'] });
    await request(app).get('/api/test');

    const output = await registry.serialize();
    expect(output).toContain('http_requests_total');
    expect(output).toContain('method="GET"');
    expect(output).toContain('status_code="200"');
    expect(output).toContain('route="/api/test"');
  });

  it('method label is uppercase', async () => {
    const app = createApp();
    await request(app).get('/api/test');

    const output = await registry.serialize();
    expect(output).toContain('method="GET"');
  });

  it('status_code label is string', async () => {
    const app = express();
    app.use(
      metricsMiddleware({
        requestsTotal,
        requestsInFlight,
        requestDuration,
        excludedRoutes: [],
        registeredPaths: [],
      }),
    );
    app.get('/missing', (_req, res) => res.status(404).send('not found'));

    await request(app).get('/missing');

    const output = await registry.serialize();
    expect(output).toContain('status_code="404"');
  });

  it('unmatched route uses UNMATCHED label', async () => {
    const app = createApp({ registeredPaths: ['/api/known'] });
    await request(app).get('/api/test');

    const output = await registry.serialize();
    expect(output).toContain('route="UNMATCHED"');
  });

  it('observes request duration in histogram', async () => {
    const app = createApp();
    await request(app).get('/api/test');

    const output = await registry.serialize();
    expect(output).toContain('http_request_duration_seconds_count');
    expect(output).toContain('http_request_duration_seconds_sum');
  });

  it('excludes configured routes', async () => {
    const app = createApp({ excludedRoutes: ['/metrics', '/health'] });

    await request(app).get('/metrics');
    await request(app).get('/health');

    const output = await registry.serialize();
    // Should not contain any http_requests_total entries
    expect(output).not.toMatch(/http_requests_total\{/);
  });

  it('does not exclude non-matching routes', async () => {
    const app = createApp({ excludedRoutes: ['/metrics'] });
    await request(app).get('/api/test');

    const output = await registry.serialize();
    expect(output).toContain('http_requests_total');
  });

  it('accumulates across multiple requests', async () => {
    const app = createApp({ registeredPaths: ['/api/test'] });

    await request(app).get('/api/test');
    await request(app).get('/api/test');
    await request(app).post('/api/test');

    const output = await registry.serialize();
    // Two label combos: GET/200, POST/200
    expect(output).toContain('method="GET"');
    expect(output).toContain('method="POST"');
    // GET count should be 2
    expect(output).toContain(
      'http_requests_total{method="GET",route="/api/test",status_code="200"} 2',
    );
  });
});

describe('metricsHandler', () => {
  let registry: MetricRegistry;

  beforeEach(() => {
    registry = new MetricRegistry();
  });

  it('returns 200 with prometheus content type', async () => {
    const app = express();
    app.get('/metrics', metricsHandler(registry));

    const res = await request(app).get('/metrics');
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toContain('text/plain');
  });

  it('body contains serialized metrics', async () => {
    registry.createCounter({ name: 'test_total', help: 'A test' });
    const app = express();
    app.get('/metrics', metricsHandler(registry));

    const res = await request(app).get('/metrics');
    expect(res.text).toContain('# HELP test_total A test');
    expect(res.text).toContain('# TYPE test_total counter');
  });

  it('body contains process_start_time_seconds', async () => {
    const app = express();
    app.get('/metrics', metricsHandler(registry));

    const res = await request(app).get('/metrics');
    expect(res.text).toContain('process_start_time_seconds');
  });
});
