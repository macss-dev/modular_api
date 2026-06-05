import { describe, it, expect } from 'vitest';
import { HealthStatus, HealthCheckResult, HealthCheck } from '../../src/core/health/health_check';
import { HealthService } from '../../src/core/health/health_service';

describe('HealthService', () => {
  describe('without checks', () => {
    it('returns pass status with version and releaseId', async () => {
      const service = new HealthService({ version: '1.0.0' });
      const response = await service.evaluate();

      expect(response.status).toBe('pass');
      expect(response.version).toBe('1.0.0');
      expect(response.checks).toEqual({});
    });

    it('releaseId defaults to version-debug', async () => {
      const service = new HealthService({ version: '1.0.0' });
      const response = await service.evaluate();

      expect(response.releaseId).toBe('1.0.0-debug');
    });

    it('releaseId can be overridden', async () => {
      const service = new HealthService({
        version: '1.0.0',
        releaseId: '1.0.0-rc1',
      });
      const response = await service.evaluate();

      expect(response.releaseId).toBe('1.0.0-rc1');
    });
  });

  describe('single check', () => {
    it('pass check → overall pass', async () => {
      const service = new HealthService({ version: '1.0.0' });
      service.addHealthCheck(new FakeCheck('database', 'pass'));

      const response = await service.evaluate();

      expect(response.status).toBe('pass');
      expect(response.checks['database']).toBeDefined();
      expect(response.checks['database'].status).toBe('pass');
    });

    it('warn check → overall warn', async () => {
      const service = new HealthService({ version: '1.0.0' });
      service.addHealthCheck(new FakeCheck('cache', 'warn', 'high latency'));

      const response = await service.evaluate();

      expect(response.status).toBe('warn');
      expect(response.checks['cache'].status).toBe('warn');
      expect(response.checks['cache'].output).toBe('high latency');
    });

    it('fail check → overall fail', async () => {
      const service = new HealthService({ version: '1.0.0' });
      service.addHealthCheck(new FakeCheck('database', 'fail'));

      const response = await service.evaluate();

      expect(response.status).toBe('fail');
    });
  });

  describe('multiple checks — worst-status-wins', () => {
    it('pass + warn → overall warn', async () => {
      const service = new HealthService({ version: '1.0.0' });
      service.addHealthCheck(new FakeCheck('database', 'pass'));
      service.addHealthCheck(new FakeCheck('cache', 'warn'));

      const response = await service.evaluate();

      expect(response.status).toBe('warn');
      expect(Object.keys(response.checks)).toHaveLength(2);
    });

    it('pass + fail → overall fail', async () => {
      const service = new HealthService({ version: '1.0.0' });
      service.addHealthCheck(new FakeCheck('database', 'pass'));
      service.addHealthCheck(new FakeCheck('redis', 'fail'));

      const response = await service.evaluate();

      expect(response.status).toBe('fail');
    });

    it('warn + fail → overall fail', async () => {
      const service = new HealthService({ version: '1.0.0' });
      service.addHealthCheck(new FakeCheck('cache', 'warn'));
      service.addHealthCheck(new FakeCheck('database', 'fail'));

      const response = await service.evaluate();

      expect(response.status).toBe('fail');
    });

    it('pass + pass + pass → overall pass', async () => {
      const service = new HealthService({ version: '1.0.0' });
      service.addHealthCheck(new FakeCheck('db', 'pass'));
      service.addHealthCheck(new FakeCheck('cache', 'pass'));
      service.addHealthCheck(new FakeCheck('queue', 'pass'));

      const response = await service.evaluate();

      expect(response.status).toBe('pass');
      expect(Object.keys(response.checks)).toHaveLength(3);
    });
  });

  describe('responseTime measurement', () => {
    it('responseTime is measured in milliseconds', async () => {
      const service = new HealthService({ version: '1.0.0' });
      service.addHealthCheck(new SlowCheck('database', 100));

      const response = await service.evaluate();

      expect(response.checks['database'].responseTime).toBeDefined();
      expect(response.checks['database'].responseTime!).toBeGreaterThanOrEqual(90);
    });
  });

  describe('timeout', () => {
    it('check that exceeds timeout is marked as fail', async () => {
      const service = new HealthService({ version: '1.0.0' });
      // Check has 200ms timeout but takes 500ms
      service.addHealthCheck(new TimingOutCheck('slow-db', 500, 200));

      const response = await service.evaluate();

      expect(response.status).toBe('fail');
      expect(response.checks['slow-db'].status).toBe('fail');
      expect(response.checks['slow-db'].output).toContain('timeout');
    });

    it('check that completes within timeout works normally', async () => {
      const service = new HealthService({ version: '1.0.0' });
      service.addHealthCheck(new TimingOutCheck('fast-db', 50, 5000));

      const response = await service.evaluate();

      expect(response.checks['fast-db'].status).toBe('pass');
    });
  });

  describe('parallel execution', () => {
    it('checks run in parallel, not sequentially', async () => {
      const service = new HealthService({ version: '1.0.0' });

      // Add 3 checks, each taking 200ms
      service.addHealthCheck(new SlowCheck('check1', 200));
      service.addHealthCheck(new SlowCheck('check2', 200));
      service.addHealthCheck(new SlowCheck('check3', 200));

      const start = Date.now();
      await service.evaluate();
      const elapsed = Date.now() - start;

      // If sequential: ~600ms. If parallel: ~200ms.
      expect(elapsed).toBeLessThan(500);
    });
  });

  describe('exception handling', () => {
    it('check that throws exception is marked as fail', async () => {
      const service = new HealthService({ version: '1.0.0' });
      service.addHealthCheck(new ThrowingCheck('broken'));

      const response = await service.evaluate();

      expect(response.status).toBe('fail');
      expect(response.checks['broken'].status).toBe('fail');
      expect(response.checks['broken'].output).toBeDefined();
    });
  });
});

describe('HealthResponse', () => {
  it('toJson() produces IETF-compliant structure', async () => {
    const service = new HealthService({
      version: '2.0.0',
      releaseId: '2.0.0-rc1',
    });
    service.addHealthCheck(new FakeCheck('database', 'pass'));
    service.addHealthCheck(new FakeCheck('cache', 'warn', 'high latency'));

    const response = await service.evaluate();
    const json = response.toJson();

    expect(json.status).toBe('warn');
    expect(json.version).toBe('2.0.0');
    expect(json.releaseId).toBe('2.0.0-rc1');
    expect(json.checks).toBeDefined();
    expect(json.checks.database.status).toBe('pass');
    expect(json.checks.cache.status).toBe('warn');
    expect(json.checks.cache.output).toBe('high latency');
  });

  it('httpStatusCode is 200 for pass', async () => {
    const service = new HealthService({ version: '1.0.0' });
    const response = await service.evaluate();

    expect(response.httpStatusCode).toBe(200);
  });

  it('httpStatusCode is 200 for warn', async () => {
    const service = new HealthService({ version: '1.0.0' });
    service.addHealthCheck(new FakeCheck('cache', 'warn'));

    const response = await service.evaluate();

    expect(response.httpStatusCode).toBe(200);
  });

  it('httpStatusCode is 503 for fail', async () => {
    const service = new HealthService({ version: '1.0.0' });
    service.addHealthCheck(new FakeCheck('db', 'fail'));

    const response = await service.evaluate();

    expect(response.httpStatusCode).toBe(503);
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

class SlowCheck extends HealthCheck {
  readonly name: string;
  private readonly delayMs: number;

  constructor(name: string, delayMs: number) {
    super();
    this.name = name;
    this.delayMs = delayMs;
  }

  async check(): Promise<HealthCheckResult> {
    await new Promise((r) => setTimeout(r, this.delayMs));
    return new HealthCheckResult('pass');
  }
}

class TimingOutCheck extends HealthCheck {
  readonly name: string;
  private readonly delayMs: number;
  private readonly _timeout: number;

  override get timeout(): number {
    return this._timeout;
  }

  constructor(name: string, delayMs: number, timeout: number) {
    super();
    this.name = name;
    this.delayMs = delayMs;
    this._timeout = timeout;
  }

  async check(): Promise<HealthCheckResult> {
    await new Promise((r) => setTimeout(r, this.delayMs));
    return new HealthCheckResult('pass');
  }
}

class ThrowingCheck extends HealthCheck {
  readonly name: string;

  constructor(name: string) {
    super();
    this.name = name;
  }

  async check(): Promise<HealthCheckResult> {
    throw new Error('Connection refused');
  }
}
