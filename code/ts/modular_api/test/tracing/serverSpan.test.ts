import { SpanKind, SpanStatusCode } from '@opentelemetry/api';
import { InMemorySpanExporter, SimpleSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { NodeTracerProvider } from '@opentelemetry/sdk-trace-node';
import { beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { completeServerSpan, startServerSpan } from '../../src/core/tracing/serverSpan';

/**
 * Gate G4 — transport neutrality.
 *
 * **Not one line of this file imports Express, constructs a request, or opens a socket.** That is
 * the entire assertion: `startServerSpan` and `completeServerSpan` take a method, a route and a
 * header map, which is all any transport can supply. The planned gRPC transport therefore arrives as
 * a second adapter over the same functions rather than as a second copy of span construction.
 *
 * This file exists because G4 was **checked rather than assumed** at the merge gate. The span had
 * been built inline inside `tracingMiddleware`'s Express closure. Every behavioural test passed —
 * they go through HTTP, so they could not see it — and a gRPC transport would have had no choice but
 * to duplicate the logic.
 *
 * TypeScript mirror of `test/tracing/server_span_test.dart`.
 */
const exporter = new InMemorySpanExporter();
let tracer: ReturnType<NodeTracerProvider['getTracer']>;

beforeAll(() => {
  const provider = new NodeTracerProvider({ spanProcessors: [new SimpleSpanProcessor(exporter)] });
  provider.register();
  tracer = provider.getTracer('modular_api');
});

beforeEach(() => exporter.reset());

const spanNamed = (name: string) => exporter.getFinishedSpans().find((span) => span.name === name);

const start = (method: string, headers: Record<string, string> = {}) =>
  startServerSpan({ tracer, method, route: '/api/cuenta/detalle', headers });

describe('with no transport in scope', () => {
  it('a span can be started and ended', () => {
    completeServerSpan(start('post').span, { statusCode: 200 });

    expect(spanNamed('POST /api/cuenta/detalle')).toBeDefined();
  });

  it('the method is upper-cased for the span name and the attribute', () => {
    // A transport that hands over a lower-case verb must not produce a differently named span from
    // one that hands over an upper-case one.
    completeServerSpan(start('get').span, { statusCode: 200 });

    expect(spanNamed('GET /api/cuenta/detalle')?.attributes['http.request.method']).toBe('GET');
  });

  it('it is a server span carrying route and status', () => {
    completeServerSpan(start('POST').span, { statusCode: 201 });

    const span = spanNamed('POST /api/cuenta/detalle');

    expect(span?.kind).toBe(SpanKind.SERVER);
    expect(span?.attributes['url.path']).toBe('/api/cuenta/detalle');
    expect(span?.attributes['http.response.status_code']).toBe(201);
  });

  it('a header map is all propagation needs', () => {
    // The propagation policy takes a map, not a request. That is what lets a gRPC transport hand
    // over its metadata without translating it into an HTTP request first.
    completeServerSpan(
      start('POST', {
        traceparent: '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',
      }).span,
      { statusCode: 200 },
    );

    const span = spanNamed('POST /api/cuenta/detalle');

    expect(span?.spanContext().traceId).toBe('4bf92f3577b34da6a3ce929d0e0e4736');
    expect(span?.parentSpanContext?.spanId).toBe('00f067aa0ba902b7');
  });

  it('the resolved request id is returned as well as recorded', () => {
    // The caller gets it back, because a transport adapter has to echo it on the response and
    // should not have to parse the headers a second time to find it.
    const started = start('POST', { 'x-request-id': 'order-42' });
    completeServerSpan(started.span, { statusCode: 200 });

    expect(started.propagation.requestId).toBe('order-42');
    expect(
      spanNamed('POST /api/cuenta/detalle')?.attributes['http.request.header.x-request-id'],
    ).toBe('order-42');
  });
});

describe('status semantics', () => {
  it('a 5xx sets error status', () => {
    completeServerSpan(start('POST').span, { statusCode: 503 });

    expect(spanNamed('POST /api/cuenta/detalle')?.status.code).toBe(SpanStatusCode.ERROR);
  });

  it('a 4xx does not', () => {
    // On a server span a 4xx is the caller's mistake. Marking it as our error makes an error-rate
    // panel useless. (The opposite holds on a client span, where a 4xx means *our* call failed.)
    completeServerSpan(start('POST').span, { statusCode: 404 });

    expect(spanNamed('POST /api/cuenta/detalle')?.status.code).not.toBe(SpanStatusCode.ERROR);
  });

  it('an error sets error status and records the exception', () => {
    completeServerSpan(start('POST').span, { error: new Error('boom') });

    expect(spanNamed('POST /api/cuenta/detalle')?.status.code).toBe(SpanStatusCode.ERROR);
  });

  it('an aborted call is an error', () => {
    // Express-specific in origin — a client disconnecting before the response completes — but
    // expressed here as a transport-agnostic flag rather than as knowledge of `res.writableEnded`.
    completeServerSpan(start('POST').span, { statusCode: 200, aborted: true });

    expect(spanNamed('POST /api/cuenta/detalle')?.status.code).toBe(SpanStatusCode.ERROR);
  });

  it('a transport with no status code produces a span with none', () => {
    // gRPC has its own status model. Passing no HTTP status must not invent one.
    completeServerSpan(start('POST').span);

    const span = spanNamed('POST /api/cuenta/detalle');

    expect(span?.attributes['http.response.status_code']).toBeUndefined();
    expect(span?.status.code).not.toBe(SpanStatusCode.ERROR);
    expect(span?.endTime).toBeDefined();
  });
});
