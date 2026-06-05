import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import request from 'supertest';
import type { Server } from 'http';
import { ModularApi, Input, Output, UseCase } from '../../src';
import { apiRegistry } from '../../src/core/registry';

// ── Minimal UseCase for integration tests ────────────────────

class PingInput extends Input {
  toJson() {
    return {};
  }
  toSchema() {
    return { type: 'object', properties: {} };
  }
}

class PingOutput extends Output {
  get statusCode() {
    return 200;
  }
  toJson() {
    return { pong: true };
  }
  toSchema() {
    return {
      type: 'object',
      properties: { pong: { type: 'boolean' } },
    };
  }
}

class PingUseCase extends UseCase<PingInput, PingOutput> {
  readonly input: PingInput;

  constructor(input: PingInput) {
    super();
    this.input = input;
  }

  static fromJson(_json: Record<string, unknown>) {
    return new PingUseCase(new PingInput());
  }

  validate() {
    return null;
  }

  async execute() {
    return new PingOutput();
  }
}

// ── Tests ────────────────────────────────────────────────────

describe('ModularApi metrics integration', () => {
  let server: Server;

  afterEach(async () => {
    if (server) {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
    apiRegistry.clear();
  });

  async function startServer(opts: { metricsEnabled?: boolean } = {}) {
    const api = new ModularApi({
      basePath: '/api',
      title: 'Test API',
      version: '1.0.0',
      metricsEnabled: opts.metricsEnabled ?? false,
    });
    api.module('test', (m) => {
      m.usecase('ping', PingUseCase.fromJson, { inputClass: PingInput, outputClass: PingOutput });
    });
    server = await api.serve({ port: 0 });
    return server;
  }

  it('metrics disabled by default — /api/metrics returns 404', async () => {
    const srv = await startServer({ metricsEnabled: false });
    const res = await request(srv).get('/api/metrics');
    expect(res.status).toBe(404);
  });

  it('metrics enabled — GET /api/metrics returns 200 with prometheus content type', async () => {
    const srv = await startServer({ metricsEnabled: true });
    const res = await request(srv).get('/api/metrics');
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toContain('text/plain');
    expect(res.text).toContain('process_start_time_seconds');
  });

  it('metrics enabled — requests are instrumented', async () => {
    const srv = await startServer({ metricsEnabled: true });

    // Make a request to the usecase endpoint
    await request(srv).post('/api/test/ping').send({}).set('Content-Type', 'application/json');

    // Check metrics
    const res = await request(srv).get('/api/metrics');
    expect(res.text).toContain('http_requests_total');
    expect(res.text).toContain('method="POST"');
    expect(res.text).toContain('status_code="200"');
    expect(res.text).toContain('route="/api/test/ping"');
    expect(res.text).toContain('http_request_duration_seconds');
  });

  it('metrics enabled — /api/health and /api/docs are not instrumented', async () => {
    const srv = await startServer({ metricsEnabled: true });

    await request(srv).get('/api/health');
    await request(srv).get('/api/docs');

    const res = await request(srv).get('/api/metrics');
    expect(res.text).not.toContain('route="/api/health"');
    expect(res.text).not.toContain('route="/api/docs"');
  });

  it('metrics getter returns MetricsRegistrar when enabled', () => {
    const api = new ModularApi({
      basePath: '/api',
      version: '1.0.0',
      metricsEnabled: true,
    });
    expect(api.metrics).toBeDefined();
  });

  it('metrics getter returns undefined when disabled', () => {
    const api = new ModularApi({ basePath: '/api', version: '1.0.0' });
    expect(api.metrics).toBeUndefined();
  });

  it('custom metrics appear in /api/metrics output', async () => {
    const api = new ModularApi({
      basePath: '/api',
      version: '1.0.0',
      metricsEnabled: true,
    });
    api.module('test', (m) => {
      m.usecase('ping', PingUseCase.fromJson, { inputClass: PingInput, outputClass: PingOutput });
    });

    // Register custom metric
    const customCounter = api.metrics!.createCounter({
      name: 'custom_operations_total',
      help: 'Custom operations counter',
      labelNames: ['type'] as const,
    });
    customCounter.inc({ type: 'test' }, 42);

    server = await api.serve({ port: 0 });

    const res = await request(server).get('/api/metrics');
    expect(res.text).toContain('custom_operations_total');
    expect(res.text).toContain('type="test"');
    expect(res.text).toContain('42');
  });
});
