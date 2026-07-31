import {
  context as otelContext,
  SpanKind,
  SpanStatusCode,
  trace,
  type Span,
  type Tracer,
} from '@opentelemetry/api';
import type { RequestHandler } from 'express';

import { PropagationPolicy, type PropagationResult } from './propagationPolicy';

/** Property under which the server span is exposed on `res.locals`. */
export const TRACING_SPAN_LOCAL = 'modularTracingSpan';

/** Property under which the resolved propagation result is exposed on `res.locals`. */
export const PROPAGATION_RESULT_LOCAL = 'modularPropagationResult';

export interface TracingMiddlewareOptions {
  readonly tracer: Tracer;
  readonly policy?: PropagationPolicy;
  readonly excludedRoutes?: readonly string[];
}

/**
 * Creates the middleware that owns the server span.
 *
 * **Host-owned, not plugin-owned.** Installed immediately after
 * `loggingMiddleware` and therefore before every plugin middleware, which is the
 * whole point: a span created from inside a plugin slot would miss the plugin
 * middleware registered before it, leaving a hole in the waterfall exactly where
 * cold start and early middleware live (ADR-0005 decision 4).
 *
 * **Where this genuinely differs from the Dart version, rather than merely reading
 * differently.** Shelf hands a middleware the `Response` its inner handler
 * produced, so the Dart implementation reads the status code and ends the span in a
 * `finally`. Express does not: a middleware calls `next()` and never sees the
 * response. The status code and the end of the request are therefore observed
 * through `res.on('finish')`, with `res.on('close')` covering a client that
 * disconnects before the response completes. A guard makes sure the span ends
 * exactly once whichever fires first.
 *
 * Ambient propagation also differs. Dart's context is zone-based and the API
 * handles it alone; in JavaScript `context.with` needs a context manager, which the
 * application's SDK registers. Without one it degrades to a passthrough: child
 * spans created downstream become roots instead of children, rather than failing.
 * The wiring recipe in the observability guide covers this.
 */
export function tracingMiddleware(options: TracingMiddlewareOptions): RequestHandler {
  const { tracer } = options;
  const policy = options.policy ?? new PropagationPolicy();
  const excluded = new Set(options.excludedRoutes ?? []);

  return (req, res, next) => {
    // Health, metrics and docs are noise in a trace store. The host derives this
    // list from operationalPaths rather than hardcoding it.
    if (excluded.has(req.path)) {
      next();
      return;
    }

    const method = req.method.toUpperCase();
    const resolved: PropagationResult = policy.resolve(
      req.headers as Record<string, string>,
    );

    const span = tracer.startSpan(
      // Semantic convention for an HTTP server span: method then route.
      `${method} ${req.path}`,
      {
        kind: SpanKind.SERVER,
        attributes: {
          'http.request.method': method,
          'url.path': req.path,
          // The convention's name for a captured header, rather than an invented
          // one, so a reader of the trace recognises it (D6).
          ...(resolved.requestId === undefined
            ? {}
            : { 'http.request.header.x-request-id': resolved.requestId }),
        },
      },
      // The parent comes from the resolved context, never from whatever happened to
      // be ambient — the same determinism the Dart version keeps.
      resolved.context,
    );

    res.locals[TRACING_SPAN_LOCAL] = span;
    res.locals[PROPAGATION_RESULT_LOCAL] = resolved;

    let ended = false;
    const endSpan = (aborted: boolean) => {
      if (ended) return;
      ended = true;

      span.setAttribute('http.response.status_code', res.statusCode);

      if (aborted) {
        span.setStatus({ code: SpanStatusCode.ERROR, message: 'client disconnected' });
      } else if (res.statusCode >= 500) {
        // 5xx is ours; 4xx is the caller's. Marking client mistakes as errors makes
        // an error-rate panel useless.
        span.setStatus({ code: SpanStatusCode.ERROR, message: `HTTP ${res.statusCode}` });
      }

      span.end();
    };

    res.on('finish', () => endSpan(false));
    res.on('close', () => endSpan(!res.writableEnded));

    // Ambient for everything downstream, so a child span created in a use case, a
    // database command or an outbound call attaches by itself.
    otelContext.with(trace.setSpan(resolved.context, span), () => {
      next();
    });
  };
}
