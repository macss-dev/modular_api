import { SpanKind, SpanStatusCode, type Span, type Tracer } from '@opentelemetry/api';

import { PropagationPolicy, type PropagationResult } from './propagationPolicy';

/** The server span for one inbound call, plus what propagation resolved. */
export interface ServerSpanStart {
  readonly span: Span;
  readonly propagation: PropagationResult;
}

export interface StartServerSpanOptions {
  readonly tracer: Tracer;
  readonly method: string;
  readonly route: string;
  readonly headers: Record<string, string>;
  readonly policy?: PropagationPolicy;
}

/**
 * Opens a server span for one inbound call.
 *
 * **Deliberately transport-neutral** (gate G4). Nothing in this file mentions HTTP, Express, or a
 * request object: it takes a method, a route and a header map, which is all any transport can
 * supply. `tracingMiddleware` is a thin adapter from Express to this, and the planned gRPC transport
 * arrives the same way — as another adapter, not as a second copy of span construction.
 *
 * This was extracted when G4 was checked rather than assumed. The span had been built inline inside
 * the middleware's Express closure, which satisfied every behavioural test and would have forced a
 * gRPC transport to duplicate it.
 */
export function startServerSpan(options: StartServerSpanOptions): ServerSpanStart {
  const method = options.method.toUpperCase();
  const policy = options.policy ?? new PropagationPolicy();
  const resolved = policy.resolve(options.headers);

  const span = options.tracer.startSpan(
    // Semantic convention for a server span: method then route.
    `${method} ${options.route}`,
    {
      kind: SpanKind.SERVER,
      attributes: {
        'http.request.method': method,
        'url.path': options.route,
        // The convention's name for a captured header rather than an invented one, so a reader of
        // the trace recognises it (D6).
        ...(resolved.requestId === undefined
          ? {}
          : { 'http.request.header.x-request-id': resolved.requestId }),
      },
    },
    // The parent comes from the resolved context, never from whatever happened to be ambient.
    resolved.context,
  );

  return { span, propagation: resolved };
}

export interface CompleteServerSpanOptions {
  readonly statusCode?: number;
  readonly error?: unknown;
  /** A client that disconnected before the response completed. */
  readonly aborted?: boolean;
}

/**
 * Records the outcome on `span` and ends it.
 *
 * `statusCode` is undefined when the call produced no status — a transport that has no such concept,
 * or a failure before one was determined.
 */
export function completeServerSpan(
  span: Span,
  { statusCode, error, aborted = false }: CompleteServerSpanOptions = {},
): void {
  if (statusCode !== undefined) {
    span.setAttribute('http.response.status_code', statusCode);
  }

  if (error !== undefined) {
    span.recordException(error instanceof Error ? error : new Error(String(error)));
    span.setStatus({ code: SpanStatusCode.ERROR, message: 'request failed' });
  } else if (aborted) {
    span.setStatus({ code: SpanStatusCode.ERROR, message: 'client disconnected' });
  } else if (statusCode !== undefined && statusCode >= 500) {
    // 5xx is ours; 4xx is the caller's. Marking client mistakes as errors makes an error-rate panel
    // useless.
    span.setStatus({ code: SpanStatusCode.ERROR, message: `HTTP ${statusCode}` });
  }

  span.end();
}
