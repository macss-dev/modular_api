import { describe, it, expect } from 'vitest';
import express from 'express';
import request from 'supertest';
import { HealthStatus, HealthCheckResult, HealthCheck } from '../../src/core/health/health_check';
import { HealthService } from '../../src/core/health/health_service';
import { healthHandler } from '../../src/core/health/health_handler';

/** Helper: create a minimal Express app with the health handler mounted. */
function createApp(service: HealthService) {
  const app = express();
  app.get('/health', healthHandler(service));
  return app;
}

describe('healthHandler — HTTP integration', () => {
  it('GET /health returns 200 with application/health+json content-type', async () => {
    const service = new HealthService({ version: '1.0.0' });
    const app = createApp(service);

    const res = await request(app).get('/health');

    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toContain('application/health+json');
  });

  it('GET /health body is valid JSON with IETF structure', async () => {
    const service = new HealthService({
      version: '2.0.0',
      releaseId: '2.0.0-rc1',
    });
    const app = createApp(service);

    const res = await request(app).get('/health');

    expect(res.body.status).toBe('pass');
    expect(res.body.version).toBe('2.0.0');
    expect(res.body.releaseId).toBe('2.0.0-rc1');
    expect(res.body.checks).toBeDefined();
  });

  it('GET /health returns 200 when checks pass', async () => {
    const service = new HealthService({ version: '1.0.0' });
    service.addHealthCheck(new FakeCheck('database', 'pass'));
    const app = createApp(service);

    const res = await request(app).get('/health');

    expect(res.status).toBe(200);
    expect(res.body.status).toBe('pass');
    expect(res.body.checks.database.status).toBe('pass');
  });

  it('GET /health returns 200 when status is warn', async () => {
    const service = new HealthService({ version: '1.0.0' });
    service.addHealthCheck(new FakeCheck('cache', 'warn', 'high latency'));
    const app = createApp(service);

    const res = await request(app).get('/health');

    expect(res.status).toBe(200);
    expect(res.body.status).toBe('warn');
  });

  it('GET /health returns 503 when any check fails', async () => {
    const service = new HealthService({ version: '1.0.0' });
    service.addHealthCheck(new FakeCheck('database', 'pass'));
    service.addHealthCheck(new FakeCheck('redis', 'fail'));
    const app = createApp(service);

    const res = await request(app).get('/health');

    expect(res.status).toBe(503);
    expect(res.body.status).toBe('fail');
  });

  it('GET /health includes all check results in response body', async () => {
    const service = new HealthService({ version: '1.0.0' });
    service.addHealthCheck(new FakeCheck('database', 'pass'));
    service.addHealthCheck(new FakeCheck('cache', 'warn', 'high latency'));
    service.addHealthCheck(new FakeCheck('queue', 'pass'));
    const app = createApp(service);

    const res = await request(app).get('/health');
    const checks = res.body.checks;

    expect(Object.keys(checks)).toHaveLength(3);
    expect(checks.database).toBeDefined();
    expect(checks.cache).toBeDefined();
    expect(checks.queue).toBeDefined();
  });

  it('GET /health check results include responseTime', async () => {
    const service = new HealthService({ version: '1.0.0' });
    service.addHealthCheck(new FakeCheck('database', 'pass'));
    const app = createApp(service);

    const res = await request(app).get('/health');

    expect(typeof res.body.checks.database.responseTime).toBe('number');
  });
});

// ─── Test doubles ─────────────────────────────────────────────────────────────

class FakeCheck extends HealthCheck {
  readonly name: string;
  private readonly _status: HealthStatus;
  private readonly _output?: string;

  constructor(name: string, status: HealthStatus, output?: string) {
    super();
    this.name = name;
    this._status = status;
    this._output = output;
  }

  async check(): Promise<HealthCheckResult> {
    return new HealthCheckResult(this._status, { output: this._output });
  }
}
