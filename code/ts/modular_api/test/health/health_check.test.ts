import { describe, it, expect } from 'vitest';
import { HealthStatus, HealthCheckResult, HealthCheck } from '../../src/core/health/health_check';

describe('HealthStatus', () => {
  it('has exactly three values: pass, warn, fail', () => {
    const values: HealthStatus[] = ['pass', 'warn', 'fail'];
    expect(values).toHaveLength(3);
  });
});

describe('HealthCheckResult', () => {
  it('creates a pass result with minimal fields', () => {
    const result = new HealthCheckResult('pass');

    expect(result.status).toBe('pass');
    expect(result.responseTime).toBeUndefined();
    expect(result.output).toBeUndefined();
  });

  it('creates a warn result with output', () => {
    const result = new HealthCheckResult('warn', {
      output: 'high latency',
    });

    expect(result.status).toBe('warn');
    expect(result.output).toBe('high latency');
  });

  it('creates a fail result with responseTime and output', () => {
    const result = new HealthCheckResult('fail', {
      responseTime: 5000,
      output: 'connection refused',
    });

    expect(result.status).toBe('fail');
    expect(result.responseTime).toBe(5000);
    expect(result.output).toBe('connection refused');
  });

  it('toJson() includes status always', () => {
    const result = new HealthCheckResult('pass');
    const json = result.toJson();

    expect(json.status).toBe('pass');
    expect('responseTime' in json).toBe(false);
    expect('output' in json).toBe(false);
  });

  it('toJson() includes responseTime when present', () => {
    const result = new HealthCheckResult('pass', { responseTime: 12 });
    const json = result.toJson();

    expect(json.status).toBe('pass');
    expect(json.responseTime).toBe(12);
  });

  it('toJson() includes output when present', () => {
    const result = new HealthCheckResult('warn', { output: 'high latency' });
    const json = result.toJson();

    expect(json.status).toBe('warn');
    expect(json.output).toBe('high latency');
  });

  it('toJson() includes all fields when all present', () => {
    const result = new HealthCheckResult('fail', {
      responseTime: 5000,
      output: 'timeout',
    });
    const json = result.toJson();

    expect(json.status).toBe('fail');
    expect(json.responseTime).toBe(5000);
    expect(json.output).toBe('timeout');
  });

  it('withResponseTime() returns a copy with responseTime set', () => {
    const result = new HealthCheckResult('pass', { output: 'ok' });
    const withTime = result.withResponseTime(42);

    expect(withTime.responseTime).toBe(42);
    expect(withTime.status).toBe('pass');
    expect(withTime.output).toBe('ok');
    // Original unchanged
    expect(result.responseTime).toBeUndefined();
  });
});

describe('HealthCheck abstract class', () => {
  it('default timeout is 5000ms', () => {
    const check = new PassingHealthCheck('test-check');
    expect(check.timeout).toBe(5000);
  });

  it('custom timeout is respected', () => {
    const check = new CustomTimeoutCheck('slow-check');
    expect(check.timeout).toBe(10000);
  });

  it('name is preserved', () => {
    const check = new PassingHealthCheck('database');
    expect(check.name).toBe('database');
  });

  it('check() returns a HealthCheckResult', async () => {
    const check = new PassingHealthCheck('database');
    const result = await check.check();

    expect(result).toBeInstanceOf(HealthCheckResult);
    expect(result.status).toBe('pass');
  });
});

// ─── Test doubles ─────────────────────────────────────────────────────────────

class PassingHealthCheck extends HealthCheck {
  readonly name: string;

  constructor(name: string) {
    super();
    this.name = name;
  }

  async check(): Promise<HealthCheckResult> {
    return new HealthCheckResult('pass');
  }
}

class CustomTimeoutCheck extends HealthCheck {
  readonly name: string;
  override get timeout(): number {
    return 10000;
  }

  constructor(name: string) {
    super();
    this.name = name;
  }

  async check(): Promise<HealthCheckResult> {
    return new HealthCheckResult('pass');
  }
}
