import { InMemorySpanExporter, SimpleSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { NodeTracerProvider } from '@opentelemetry/sdk-trace-node';
import express, { type Express } from 'express';
import supertest from 'supertest';
import { beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { LogLevel, type TraceFieldFormatter } from '../../src/core/logger/logger';
import { loggingMiddleware } from '../../src/core/logger/logging_middleware';
import { REQUEST_ID_HEADER } from '../../src/core/tracing/propagationPolicy';
import { tracingMiddleware } from '../../src/core/tracing/tracingMiddleware';
import { TracingOptions } from '../../src/core/tracing/tracingOptions';
import { TRACEPARENT_HEADER } from '../../src/core/tracing/w3cTraceContextPropagator';

/**
 * TypeScript mirror of `test/logger/log_trace_correlation_test.dart`.
 *
 * These tests are why D12 was reversed. With logging outermost, making the log carry the
 * trace id required the logger to own it and the span to adopt it — which Dart can express
 * through `startSpan(spanContext:)` and this API cannot. Seeding a trace id here means
 * seeding a *parent*, and a seeded parent's trace flags made the default ParentBased
 * sampler drop the span entirely: two tests failed with no spans exported at all.
 *
 * Tracing is now outermost in all three implementations, so the logger reads the ids from
 * the ambient span and none of that scaffolding exists.
 */
const TRACE_ID = '4bf92f3577b34da6a3ce929d0e0e4736';
const TRACEPARENT = `00-${TRACE_ID}-00f067aa0ba902b7-01`;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

const exporter = new InMemorySpanExporter();
let options: TracingOptions;

beforeAll(() => {
  const provider = new NodeTracerProvider({
    spanProcessors: [new SimpleSpanProcessor(exporter)],
  });
  provider.register();
  options = new TracingOptions({ tracerProvider: provider });
});

beforeEach(() => exporter.reset());

interface Captured {
  logs: Record<string, unknown>[];
}

function appWith({
  tracing,
  traceFieldFormatter,
}: {
  tracing?: TracingOptions;
  traceFieldFormatter?: TraceFieldFormatter;
} = {}): { app: Express; captured: Captured } {
  const captured: Captured = { logs: [] };

  const app = express();
  // Tracing outermost, logging inside — the order the host builds (D12 reversed).
  if (tracing !== undefined) {
    app.use(tracingMiddleware({ tracer: tracing.tracer, policy: tracing.policy }));
  }
  app.use(
    loggingMiddleware({
      logLevel: LogLevel.debug,
      serviceName: 'modular_api-test',
      writeFn: (line) => captured.logs.push(JSON.parse(line) as Record<string, unknown>),
      ...(traceFieldFormatter === undefined ? {} : { traceFieldFormatter }),
    }),
  );
  app.use((_req, res) => res.send('ok'));

  return { app, captured };
}

const lineWithMsg = (logs: Record<string, unknown>[], msg: string) =>
  logs.find((log) => log['msg'] === msg);

describe('without TracingOptions — the compatibility guarantee (D5b)', () => {
  it('trace_id keeps its UUID shape', async () => {
    // The whole point of gating the format change on adoption: a consumer who does not
    // enable tracing sees exactly what they saw before, so no log query, no dashboard
    // and no alert breaks.
    const { app, captured } = appWith();

    await supertest(app).get('/api/cuenta/ping');

    expect(captured.logs[0]?.['trace_id']).toMatch(UUID_PATTERN);
  });

  it('an incoming traceparent is ignored, not adopted', async () => {
    const { app, captured } = appWith();

    await supertest(app).get('/api/cuenta/ping').set(TRACEPARENT_HEADER, TRACEPARENT);

    expect(captured.logs[0]?.['trace_id']).not.toBe(TRACE_ID);
  });

  it('no span_id is emitted', async () => {
    const { app, captured } = appWith();

    await supertest(app).get('/api/cuenta/ping');

    expect(captured.logs[0]).not.toHaveProperty('span_id');
  });

  it('X-Request-ID is still honoured as the trace_id, as it always was', async () => {
    const { app, captured } = appWith();

    await supertest(app).get('/api/cuenta/ping').set(REQUEST_ID_HEADER, 'legacy-correlation');

    expect(captured.logs[0]?.['trace_id']).toBe('legacy-correlation');
  });
});

describe('with TracingOptions', () => {
  it('trace_id is the 32-hex W3C id', async () => {
    const { app, captured } = appWith({ tracing: options });

    await supertest(app).get('/api/cuenta/ping').set(TRACEPARENT_HEADER, TRACEPARENT);

    expect(captured.logs[0]?.['trace_id']).toBe(TRACE_ID);
  });

  it('trace_id is a generated 32-hex id when no header arrives', async () => {
    const { app, captured } = appWith({ tracing: options });

    await supertest(app).get('/api/cuenta/ping');

    expect(captured.logs[0]?.['trace_id']).toMatch(/^[0-9a-f]{32}$/);
  });

  it('request_id carries the original X-Request-ID', async () => {
    // D6: the caller's token is preserved beside the trace id rather than promoted into
    // it, so anyone correlating by what they sent keeps working.
    const { app, captured } = appWith({ tracing: options });

    await supertest(app).get('/api/cuenta/ping').set(REQUEST_ID_HEADER, 'order-42');

    expect(captured.logs[0]?.['request_id']).toBe('order-42');
    expect(captured.logs[0]?.['trace_id']).not.toBe('order-42');
  });

  it('request_id is absent when the caller sent none', async () => {
    const { app, captured } = appWith({ tracing: options });

    await supertest(app).get('/api/cuenta/ping');

    expect(captured.logs[0]).not.toHaveProperty('request_id');
  });

  it('the trace_id in the log equals the exported span trace id', async () => {
    // The assertion the whole stage exists for. If these two ever disagree, a log line
    // points at a trace that does not contain it.
    const { app, captured } = appWith({ tracing: options });

    await supertest(app).get('/api/cuenta/ping');

    const span = exporter.getFinishedSpans().find((s) => s.name === 'GET /api/cuenta/ping');
    expect(captured.logs[0]?.['trace_id']).toBe(span?.spanContext().traceId);
  });

  describe('span_id', () => {
    it('is emitted on lines logged after the span exists', async () => {
      const { app, captured } = appWith({ tracing: options });

      await supertest(app).get('/api/cuenta/ping');

      const span = exporter.getFinishedSpans().find((s) => s.name === 'GET /api/cuenta/ping');
      expect(lineWithMsg(captured.logs, 'request completed')?.['span_id']).toBe(
        span?.spanContext().spanId,
      );
    });

    it('reaches the request-completed line, emitted after the span ends', async () => {
      // The line that matters most: it carries duration_ms. It is emitted from inside the
      // span's active scope, so the ambient span is still there to read.
      const { app, captured } = appWith({ tracing: options });

      await supertest(app).get('/api/cuenta/ping');

      const completed = lineWithMsg(captured.logs, 'request completed');
      expect(completed?.['duration_ms']).toBeDefined();
      expect(completed?.['span_id']).toBeDefined();
    });

    it('reaches request-received too, because the span already exists', async () => {
      // A limit the earlier design accepted as inevitable and the reversal removed.
      const { app, captured } = appWith({ tracing: options });

      await supertest(app).get('/api/cuenta/ping');

      const received = lineWithMsg(captured.logs, 'request received');
      expect(received?.['span_id']).toBeDefined();
      expect(received?.['trace_id']).toBeDefined();
    });
  });
});

describe('the platform correlation field', () => {
  it('is absent by default', async () => {
    // Roadmap invariant 7: the framework emits open formats and nothing
    // vendor-specific.
    const { app, captured } = appWith({ tracing: options });

    await supertest(app).get('/api/cuenta/ping');

    expect(Object.keys(captured.logs[0] ?? {}).some((key) => key.includes('googleapis'))).toBe(
      false,
    );
  });

  it('is emitted when the application supplies a formatter', async () => {
    const { app, captured } = appWith({
      tracing: options,
      // What socia supplies: the GCP field, built from ids the framework resolved and a
      // project id only the application knows.
      traceFieldFormatter: (traceId, spanId) => ({
        'logging.googleapis.com/trace': `projects/sociacacsi/traces/${traceId}`,
        ...(spanId === undefined ? {} : { 'logging.googleapis.com/spanId': spanId }),
      }),
    });

    await supertest(app).get('/api/cuenta/ping');

    const completed = lineWithMsg(captured.logs, 'request completed');
    expect(completed?.['logging.googleapis.com/trace']).toMatch(
      /^projects\/sociacacsi\/traces\//,
    );
    expect(completed?.['logging.googleapis.com/spanId']).toBeDefined();
  });

  it('is not emitted without tracing, even when a formatter is supplied', async () => {
    // A formatter with no trace context to format would produce a field pointing at a
    // trace that does not exist.
    const { app, captured } = appWith({
      traceFieldFormatter: (traceId) => ({
        'logging.googleapis.com/trace': `projects/x/traces/${traceId}`,
      }),
    });

    await supertest(app).get('/api/cuenta/ping');

    expect(captured.logs[0]).not.toHaveProperty('logging.googleapis.com/trace');
  });
});
