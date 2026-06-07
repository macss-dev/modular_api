import { describe, it, expect, afterEach } from 'vitest';
import request from 'supertest';
import type { Server } from 'http';
import { ModularApi, Input, Output, UseCase, LogLevel } from '../../src';
import type { ModularLogger } from '../../src';

// ── Minimal UseCase for integration tests ────────────────────

class PingInput implements Input {
  toJson() {
    return {};
  }
  toSchema() {
    return { type: 'object', properties: {} };
  }
}

class PingOutput implements Output {
  get statusCode() {
    return 200;
  }
  toJson() {
    return { pong: true };
  }
  toSchema() {
    return { type: 'object', properties: { pong: { type: 'boolean' } } };
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

// ── UseCase that uses the logger ──────────────────────────────

class LoggingUseCase extends UseCase<PingInput, PingOutput> {
  readonly input: PingInput;

  constructor(input: PingInput) {
    super();
    this.input = input;
  }

  static fromJson(_json: Record<string, unknown>) {
    return new LoggingUseCase(new PingInput());
  }

  validate() {
    return null;
  }

  async execute() {
    this.logger?.info('executing inside use case', { custom: 'field' });
    return new PingOutput();
  }
}

// ── Tests ────────────────────────────────────────────────────

describe('Logger integration (TypeScript)', () => {
  let server: Server | undefined;

  afterEach(async () => {
    if (server) {
      await new Promise<void>((resolve, reject) =>
        server!.close((err) => (err ? reject(err) : resolve())),
      );
      server = undefined;
    }
  });

  it('UseCase inherits logger property (undefined by default)', () => {
    const uc = PingUseCase.fromJson({});
    expect(uc.logger).toBeUndefined();
  });

  it('UseCase.logger is injectable', () => {
    const uc = PingUseCase.fromJson({});
    const fakeLogger: ModularLogger = {
      traceId: 'test-trace',
      emergency: () => {},
      alert: () => {},
      critical: () => {},
      error: () => {},
      warning: () => {},
      notice: () => {},
      info: () => {},
      debug: () => {},
    };
    uc.logger = fakeLogger;
    expect(uc.logger).toBe(fakeLogger);
    expect(uc.logger.traceId).toBe('test-trace');
  });

  it('X-Request-ID response header is set by the middleware', async () => {
    const api = new ModularApi({
      basePath: '/api',
      title: 'Logger Test',
      logLevel: LogLevel.debug,
    });
    api.module('test', (m) => m.usecase('ping', PingUseCase.fromJson, { inputClass: PingInput, outputClass: PingOutput }));
    server = await api.serve({ port: 0 });

    const res = await request(server).post('/api/test/ping').send({});

    expect(res.status).toBe(200);
    expect(res.headers['x-request-id']).toBeTruthy();
  });

  it('X-Request-ID is propagated from request header', async () => {
    const api = new ModularApi({
      basePath: '/api',
      title: 'Logger Test',
      logLevel: LogLevel.debug,
    });
    api.module('test', (m) => m.usecase('ping', PingUseCase.fromJson, { inputClass: PingInput, outputClass: PingOutput }));
    server = await api.serve({ port: 0 });

    const res = await request(server)
      .post('/api/test/ping')
      .set('X-Request-ID', 'my-custom-trace')
      .send({});

    expect(res.status).toBe(200);
    expect(res.headers['x-request-id']).toBe('my-custom-trace');
  });

  it('logger is available inside UseCase.execute()', async () => {
    const api = new ModularApi({
      basePath: '/api',
      title: 'Logger Test',
      logLevel: LogLevel.debug,
    });
    api.module('test', (m) => m.usecase('log', LoggingUseCase.fromJson, { inputClass: PingInput, outputClass: PingOutput }));
    server = await api.serve({ port: 0 });

    const res = await request(server).post('/api/test/log').send({});

    // If logger wasn't injected, the ?. would make it a no-op and execute would still succeed
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ pong: true });
  });

  it('/api/health is excluded from logging (no X-Request-ID header)', async () => {
    const api = new ModularApi({
      basePath: '/api',
      title: 'Logger Test',
      logLevel: LogLevel.debug,
    });
    api.module('test', (m) => m.usecase('ping', PingUseCase.fromJson, { inputClass: PingInput, outputClass: PingOutput }));
    server = await api.serve({ port: 0 });

    const res = await request(server).get('/api/health');

    expect(res.status).toBe(200);
    // Health endpoint is excluded from logging middleware, so no X-Request-ID
    expect(res.headers['x-request-id']).toBeUndefined();
  });
});
