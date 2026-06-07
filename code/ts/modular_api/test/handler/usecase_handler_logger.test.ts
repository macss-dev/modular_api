// ============================================================
// handler/usecase_handler_logger.test.ts
// Validates that useCaseHandler catch blocks log through the
// request-scoped logger (with trace_id) instead of
// console.error (issue #7).
// ============================================================

import { describe, it, expect } from 'vitest';
import express from 'express';
import request from 'supertest';
import { Input, Output, UseCase, type UseCaseFactory } from '../../src/core/usecase';
import { Field } from '../../src/core/schema/field';
import { useCaseHandler } from '../../src/core/usecase_handler';
import { loggingMiddleware } from '../../src/core/logger/logging_middleware';
import { LogLevel } from '../../src/core/logger/logger';
import { UseCaseException } from '../../src/core/use_case_exception';

// ── Minimal DTOs ───────────────────────────────────────────

class PingInput extends Input {
  @Field.string({ description: 'payload' })
  payload!: string;

  static fromJson(json: Record<string, unknown>): PingInput {
    const i = new PingInput();
    i.payload = json['payload'] as string;
    return i;
  }
}

class PingOutput extends Output {
  @Field.string({ description: 'echo' })
  echo!: string;
  get statusCode() { return 200; }
}

// ── UseCase that throws UseCaseException ───────────────────

class FailingUseCase extends UseCase<PingInput, PingOutput> {
  readonly input: PingInput;
  constructor(input: PingInput) { super(); this.input = input; }

  static fromJson(json: Record<string, unknown>): FailingUseCase {
    return new FailingUseCase(PingInput.fromJson(json));
  }

  validate() { return null; }

  async execute(): Promise<PingOutput> {
    throw new UseCaseException({ statusCode: 422, message: 'business rule violated' });
  }
}

// ── UseCase that throws unexpected error ───────────────────

class CrashingUseCase extends UseCase<PingInput, PingOutput> {
  readonly input: PingInput;
  constructor(input: PingInput) { super(); this.input = input; }

  static fromJson(json: Record<string, unknown>): CrashingUseCase {
    return new CrashingUseCase(PingInput.fromJson(json));
  }

  validate() { return null; }

  async execute(): Promise<PingOutput> {
    throw new TypeError('cannot read property x of undefined');
  }
}

// ── Helper ─────────────────────────────────────────────────

function buildApp(
  factory: UseCaseFactory,
  logLines: string[],
  inputClass?: abstract new (...args: unknown[]) => Input,
) {
  const app = express();

  app.use(
    loggingMiddleware({
      logLevel: LogLevel.debug,
      serviceName: 'test-svc',
      writeFn: (line: string) => logLines.push(line),
    }),
  );

  app.use(express.json());
  app.post('/test', useCaseHandler(factory, { inputClass }));
  return app;
}

// ── Tests ──────────────────────────────────────────────────

describe('useCaseHandler scoped-logger integration (issue #7)', () => {
  it('logs UseCaseException through scoped logger with trace_id', async () => {
    const logLines: string[] = [];
    const app = buildApp(FailingUseCase.fromJson as UseCaseFactory, logLines, PingInput);
    const traceId = 'trace-uce-001';

    const res = await request(app)
      .post('/test')
      .set('X-Request-ID', traceId)
      .send({ payload: 'hello' });

    expect(res.status).toBe(422);

    const errorLog = logLines
      .map((l) => JSON.parse(l))
      .find(
        (e: Record<string, unknown>) =>
          e['level'] === 'error' && (e['msg'] as string).includes('UseCaseException'),
      );

    expect(errorLog).toBeDefined();
    expect(errorLog['trace_id']).toBe(traceId);
  });

  it('logs unexpected errors through scoped logger with trace_id', async () => {
    const logLines: string[] = [];
    const app = buildApp(CrashingUseCase.fromJson as UseCaseFactory, logLines, PingInput);
    const traceId = 'trace-crash-002';

    const res = await request(app)
      .post('/test')
      .set('X-Request-ID', traceId)
      .send({ payload: 'hello' });

    expect(res.status).toBe(500);

    const errorLog = logLines
      .map((l) => JSON.parse(l))
      .find(
        (e: Record<string, unknown>) =>
          e['level'] === 'error' &&
          (e['msg'] as string).includes('Unexpected error'),
      );

    expect(errorLog).toBeDefined();
    expect(errorLog['trace_id']).toBe(traceId);
  });

  it('does not throw when logger is unavailable (excluded routes)', async () => {
    // Build an app WITHOUT loggingMiddleware — simulates excluded route
    const app = express();
    app.use(express.json());
    app.post('/test', useCaseHandler(FailingUseCase.fromJson as UseCaseFactory, { inputClass: PingInput }));

    const res = await request(app)
      .post('/test')
      .send({ payload: 'hello' });

    // Should still return the correct error response even without logger
    expect(res.status).toBe(422);
    expect(res.body).toHaveProperty('message', 'business rule violated');
  });
});
