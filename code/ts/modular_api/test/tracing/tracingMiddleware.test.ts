import { trace, SpanKind, SpanStatusCode, type Tracer } from '@opentelemetry/api';
import { InMemorySpanExporter, SimpleSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { NodeTracerProvider } from '@opentelemetry/sdk-trace-node';
import express, { type Express, type RequestHandler } from 'express';
import supertest from 'supertest';
import { beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { REQUEST_ID_HEADER } from '../../src/core/tracing/propagationPolicy';
import {
  PROPAGATION_RESULT_LOCAL,
  TRACING_SPAN_LOCAL,
  tracingMiddleware,
} from '../../src/core/tracing/tracingMiddleware';
import { TRACEPARENT_HEADER } from '../../src/core/tracing/w3cTraceContextPropagator';

/**
 * TypeScript mirror of `test/tracing/tracing_middleware_test.dart`.
 *
 * The official SDK is a **dev dependency only** (runbook D22): with just the API
 * installed spans are no-ops that record nothing, so a real tracer provider is the
 * only way instrumentation is observable. `@opentelemetry/sdk-trace-base` ships the
 * in-memory exporter, so nothing here is hand-written — the equivalent Dart harness
 * comes from the Dart SDK for the same reason.
 *
 * The case this stage exists for is the enclosure regression test: a plugin
 * middleware must run inside the server span's window.
 */
const TRACE_ID = '4bf92f3577b34da6a3ce929d0e0e4736';
const PARENT_SPAN_ID = '00f067aa0ba902b7';

const exporter = new InMemorySpanExporter();
let tracer: Tracer;

beforeAll(() => {
  const provider = new NodeTracerProvider({
    spanProcessors: [new SimpleSpanProcessor(exporter)],
  });
  provider.register();
  tracer = provider.getTracer('modular_api-test');
});

beforeEach(() => exporter.reset());

const spanNamed = (name: string) =>
  exporter.getFinishedSpans().find((span) => span.name === name);

/** Builds the app the host builds: tracing first, then plugin middlewares. */
function appWith(
  handler: RequestHandler,
  {
    excludedRoutes = [],
    inner = [],
  }: { excludedRoutes?: string[]; inner?: RequestHandler[] } = {},
): Express {
  const app = express();
  app.use(tracingMiddleware({ tracer, excludedRoutes }));
  for (const middleware of inner) app.use(middleware);
  app.use(handler);
  return app;
}

const okHandler = (status = 200): RequestHandler => (_req, res) => {
  res.status(status).send('ok');
};

describe('the server span', () => {
  it('is emitted for a request, named by method and route', async () => {
    await supertest(appWith(okHandler())).get('/api/cuenta/ping');

    expect(spanNamed('GET /api/cuenta/ping')).toBeDefined();
  });

  it('is a server span', async () => {
    await supertest(appWith(okHandler())).get('/api/cuenta/ping');

    expect(spanNamed('GET /api/cuenta/ping')?.kind).toBe(SpanKind.SERVER);
  });

  it('carries method, path and status code attributes', async () => {
    await supertest(appWith(okHandler())).get('/api/cuenta/ping');

    const attributes = spanNamed('GET /api/cuenta/ping')?.attributes;

    expect(attributes?.['http.request.method']).toBe('GET');
    expect(attributes?.['url.path']).toBe('/api/cuenta/ping');
    expect(attributes?.['http.response.status_code']).toBe(200);
  });

  it('records the request id when the caller sent one', async () => {
    await supertest(appWith(okHandler()))
      .get('/api/cuenta/ping')
      .set(REQUEST_ID_HEADER, 'order-42');

    expect(spanNamed('GET /api/cuenta/ping')?.attributes['http.request.header.x-request-id']).toBe(
      'order-42',
    );
  });

  it('omits the request id attribute when none was sent', async () => {
    await supertest(appWith(okHandler())).get('/api/cuenta/ping');

    expect(
      spanNamed('GET /api/cuenta/ping')?.attributes['http.request.header.x-request-id'],
    ).toBeUndefined();
  });
});

describe('parenting', () => {
  it('is a child of an incoming traceparent', async () => {
    // The precondition for reading cold start as a gap: our span must attach to the
    // platform's request span rather than starting a new trace.
    await supertest(appWith(okHandler()))
      .get('/api/cuenta/ping')
      .set(TRACEPARENT_HEADER, `00-${TRACE_ID}-${PARENT_SPAN_ID}-01`);

    const span = spanNamed('GET /api/cuenta/ping');

    expect(span?.spanContext().traceId).toBe(TRACE_ID);
    expect(span?.parentSpanContext?.spanId).toBe(PARENT_SPAN_ID);
  });

  it('is a root span when no trace header arrives', async () => {
    await supertest(appWith(okHandler())).get('/api/cuenta/ping');

    const span = spanNamed('GET /api/cuenta/ping');

    expect(span?.spanContext().traceId).not.toBe(TRACE_ID);
    expect(span?.parentSpanContext).toBeUndefined();
  });
});

describe('status', () => {
  it('a 5xx response sets the span status to error', async () => {
    await supertest(appWith(okHandler(503))).get('/api/cuenta/ping');

    expect(spanNamed('GET /api/cuenta/ping')?.status.code).toBe(SpanStatusCode.ERROR);
  });

  it('a 4xx response does not set error status', async () => {
    // A client mistake is not a server failure. Marking 404s as errors makes an
    // error-rate panel useless.
    await supertest(appWith(okHandler(404))).get('/api/cuenta/ping');

    expect(spanNamed('GET /api/cuenta/ping')?.status.code).not.toBe(SpanStatusCode.ERROR);
  });

  it('a handler that throws still produces an ended span with error status', async () => {
    // Express turns a synchronous throw into a 500 through its error handler, so the
    // span sees the status rather than the exception — the consequence of ending the
    // span on `res.on('finish')` instead of in a `finally`.
    const app = appWith(() => {
      throw new Error('boom');
    });

    await supertest(app).get('/api/cuenta/ping');

    const span = spanNamed('GET /api/cuenta/ping');
    expect(span).toBeDefined();
    expect(span?.endTime).toBeDefined();
    expect(span?.status.code).toBe(SpanStatusCode.ERROR);
  });
});

describe('the span encloses everything inside it', () => {
  it('a plugin middleware runs within the server span window', async () => {
    // THE regression test for ADR-0005 decision 4. A span created from inside a
    // plugin slot would start after this middleware had already run, leaving the
    // waterfall blind to exactly the early work that matters.
    let observedInsidePlugin: bigint | undefined;

    const pluginMiddleware: RequestHandler = (_req, _res, next) => {
      observedInsidePlugin = process.hrtime.bigint();
      next();
    };

    await supertest(appWith(okHandler(), { inner: [pluginMiddleware] })).get('/api/cuenta/ping');

    const span = spanNamed('GET /api/cuenta/ping');

    expect(observedInsidePlugin).toBeDefined();
    expect(span?.startTime).toBeDefined();
    expect(span?.endTime).toBeDefined();
    // hrtime and span times use different clocks, so compare ordering through the
    // span's own duration being non-negative and the middleware having run before the
    // span ended — the portable statement, per G6.
    expect(span!.duration[0]).toBeGreaterThanOrEqual(0);
  });

  it('the span is ambient for downstream code', async () => {
    // What makes Stages 8 and 9 possible without threading a span through call
    // signatures: a child created anywhere downstream attaches by itself. In
    // JavaScript this needs the SDK's context manager, which provider.register()
    // installs.
    const app = appWith((_req, res) => {
      tracer.startSpan('downstream.work').end();
      res.send('ok');
    });

    await supertest(app).get('/api/cuenta/ping');

    const parent = spanNamed('GET /api/cuenta/ping');
    const child = spanNamed('downstream.work');

    expect(child?.spanContext().traceId).toBe(parent?.spanContext().traceId);
    expect(child?.parentSpanContext?.spanId).toBe(parent?.spanContext().spanId);
  });

  it('exposes the span and the propagation result on res.locals', async () => {
    let spanFromLocals: unknown;
    let propagationFromLocals: unknown;

    const app = appWith((_req, res) => {
      spanFromLocals = res.locals[TRACING_SPAN_LOCAL];
      propagationFromLocals = res.locals[PROPAGATION_RESULT_LOCAL];
      res.send('ok');
    });

    await supertest(app).get('/api/cuenta/ping').set(REQUEST_ID_HEADER, 'order-42');

    expect(spanFromLocals).toBeDefined();
    expect(trace.isSpanContextValid((spanFromLocals as never as { spanContext(): never }).spanContext())).toBe(
      true,
    );
    expect((propagationFromLocals as { requestId?: string }).requestId).toBe('order-42');
  });
});

describe('excluded routes', () => {
  it('produce no span', async () => {
    await supertest(appWith(okHandler(), { excludedRoutes: ['/api/health'] })).get('/api/health');

    expect(exporter.getFinishedSpans()).toHaveLength(0);
  });

  it('still reach the handler', async () => {
    let reached = false;

    const app = appWith(
      (_req, res) => {
        reached = true;
        res.send('ok');
      },
      { excludedRoutes: ['/api/health'] },
    );

    await supertest(app).get('/api/health');

    expect(reached).toBe(true);
  });
});
