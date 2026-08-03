import { context as otelContext, SpanKind, SpanStatusCode, trace, type Tracer } from '@opentelemetry/api';
import { InMemorySpanExporter, SimpleSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { NodeTracerProvider } from '@opentelemetry/sdk-trace-node';
import { W3CTraceContextPropagator } from '@opentelemetry/core';
import { beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { REQUEST_ID_HEADER } from '../src/clientTracing';
import { HttpServiceClient, ServiceClientConfig, ServiceRequest } from '../src/restClient';

/**
 * TypeScript mirror of `test/tracing_test.dart`.
 *
 * **This is the stage that satisfies G7 for `socia`.** Its
 * `POST /api/cuenta/get-cuenta-detalle` performs no database work at all — it is an HTTP
 * proxy to an upstream `impulsa` service (runbook D17) — so the client span is what shows
 * whether those 8–20 second bursts are spent in the outbound call or before it.
 *
 * Note the propagator source: `@opentelemetry/core` is imported **in the test only**, to
 * stand in for whatever the host configures globally. The package under test never imports
 * it, which is the point — it reads `propagation.inject`, and the Stage 1b guard forbids
 * that package as a runtime dependency.
 */
const exporter = new InMemorySpanExporter();
let tracer: Tracer;

beforeAll(() => {
  const provider = new NodeTracerProvider({ spanProcessors: [new SimpleSpanProcessor(exporter)] });
  provider.register({ propagator: new W3CTraceContextPropagator() });
  tracer = provider.getTracer('test-host');
});

beforeEach(() => exporter.reset());

const spanNamed = (name: string) =>
  exporter.getFinishedSpans().find((span) => span.name === name);

let sentHeaders: Record<string, string>;

function clientFor({
  status = 200,
  defaultHeaders = {},
  throwError,
}: {
  status?: number;
  defaultHeaders?: Record<string, string>;
  throwError?: unknown;
} = {}): HttpServiceClient {
  sentHeaders = {};
  return new HttpServiceClient(
    new ServiceClientConfig({
      serviceId: 'impulsa',
      baseUrl: 'https://impulsa.example/api',
      redactedSummary: 'impulsa.example',
      defaultHeaders,
    }),
    {
      fetchImpl: (async (_url: string | URL, init?: RequestInit) => {
        sentHeaders = { ...((init?.headers ?? {}) as Record<string, string>) };
        if (throwError !== undefined) throw throwError;
        return new Response(JSON.stringify({ ok: true }), {
          status,
          headers: { 'content-type': 'application/json' },
        });
      }) as typeof fetch,
    },
  );
}

const call = (client: HttpServiceClient, operationId = 'get-cuenta-detalle') =>
  client.execute(
    new ServiceRequest({
      operationId,
      method: 'POST',
      path: operationId,
      body: { dni: '12345678' },
    }),
    { decoder: (json) => json },
  );

async function withinServerSpan(body: () => Promise<unknown>): Promise<void> {
  const serverSpan = tracer.startSpan('POST /api/cuenta/get-cuenta-detalle', {
    kind: SpanKind.SERVER,
  });
  await otelContext.with(trace.setSpan(otelContext.active(), serverSpan), body);
  serverSpan.end();
}

describe('with an active server span', () => {
  it('emits a client span named by method and operation', async () => {
    await withinServerSpan(() => call(clientFor()));

    expect(spanNamed('POST get-cuenta-detalle')).toBeDefined();
  });

  it('the client span is kind=client and a child of the server span', async () => {
    await withinServerSpan(() => call(clientFor()));

    const server = spanNamed('POST /api/cuenta/get-cuenta-detalle');
    const client = spanNamed('POST get-cuenta-detalle');

    expect(client?.kind).toBe(SpanKind.CLIENT);
    expect(client?.spanContext().traceId).toBe(server?.spanContext().traceId);
    expect(client?.parentSpanContext?.spanId).toBe(server?.spanContext().spanId);
  });

  it('records the upstream host and path, not the full URL', async () => {
    // A full URL can carry identifiers in its path or query. server.address plus url.path
    // is what the conventions ask for and what is safe to store.
    await withinServerSpan(() => call(clientFor()));

    const attributes = spanNamed('POST get-cuenta-detalle')?.attributes;

    expect(attributes?.['server.address']).toBe('impulsa.example');
    expect(attributes?.['url.path']).toContain('get-cuenta-detalle');
    expect(attributes?.['http.request.method']).toBe('POST');
  });

  it('injects traceparent derived from the client span', async () => {
    // The header a downstream service would read. It names the CLIENT span, not the server
    // span, so a downstream hop attaches to the call rather than to its parent.
    await withinServerSpan(() => call(clientFor()));

    const client = spanNamed('POST get-cuenta-detalle');

    expect(sentHeaders['traceparent']).toBeDefined();
    expect(sentHeaders['traceparent']).toContain(client?.spanContext().traceId);
    expect(sentHeaders['traceparent']).toContain(client?.spanContext().spanId);
  });

  it('a 500 from upstream sets the client span to error', async () => {
    await withinServerSpan(() => call(clientFor({ status: 500 })));

    const client = spanNamed('POST get-cuenta-detalle');

    expect(client?.status.code).toBe(SpanStatusCode.ERROR);
    expect(client?.attributes['http.response.status_code']).toBe(500);
  });

  it('a 404 from upstream also sets error, unlike a server span', async () => {
    // On a server span a 4xx is the caller's mistake. Here it means OUR outbound call
    // failed, which is a different thing and worth distinguishing in a waterfall.
    await withinServerSpan(() => call(clientFor({ status: 404 })));

    expect(spanNamed('POST get-cuenta-detalle')?.status.code).toBe(SpanStatusCode.ERROR);
  });

  it('a transport failure ends the span with error and no status code', async () => {
    // The case that matters for the socia investigation: a call that never returns.
    await withinServerSpan(() => call(clientFor({ throwError: new Error('connection reset') })));

    const client = spanNamed('POST get-cuenta-detalle');

    expect(client?.status.code).toBe(SpanStatusCode.ERROR);
    expect(client?.attributes['http.response.status_code']).toBeUndefined();
  });

  it('the span is ended, which is the G7 measurement', async () => {
    // What the whole effort is for: separating "time spent calling impulsa" from "time
    // spent everywhere else". The number itself is production's to report.
    await withinServerSpan(() => call(clientFor()));

    expect(spanNamed('POST get-cuenta-detalle')?.endTime).toBeDefined();
  });
});

describe('X-Request-ID forwarding (D23)', () => {
  it('an inbound request id is forwarded on the outbound call', async () => {
    await withinServerSpan(() =>
      call(clientFor({ defaultHeaders: { [REQUEST_ID_HEADER]: 'order-42' } })),
    );

    expect(sentHeaders[REQUEST_ID_HEADER]).toBe('order-42');
  });

  it('it is forwarded even with tracing off', async () => {
    // The half of D23 that repairs D20: impulsa does not run modular_api, so trace context
    // dies there. If it logs the request id, log correlation still crosses the boundary —
    // and that must not depend on tracing being enabled.
    await call(clientFor({ defaultHeaders: { [REQUEST_ID_HEADER]: 'order-42' } }));

    expect(sentHeaders[REQUEST_ID_HEADER]).toBe('order-42');
  });

  it('none is invented when the caller sent none', async () => {
    // We forward, we do not generate. Minting one belongs at an edge that knows it is the
    // edge.
    await call(clientFor());

    expect(sentHeaders[REQUEST_ID_HEADER]).toBeUndefined();
  });
});

describe('without an active server span (gate G3)', () => {
  it('no client span is emitted', async () => {
    // Not "a non-recording span": none at all.
    await call(clientFor());

    expect(exporter.getFinishedSpans()).toHaveLength(0);
  });

  it('no traceparent is injected', async () => {
    // A header naming a span that does not exist would mislead a downstream service into
    // attaching to nothing.
    await call(clientFor());

    expect(sentHeaders['traceparent']).toBeUndefined();
  });

  it('the call still succeeds', async () => {
    const result = await call(clientFor());

    expect(result.isSuccess).toBe(true);
  });
});
