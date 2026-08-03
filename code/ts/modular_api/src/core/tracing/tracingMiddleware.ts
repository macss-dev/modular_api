import { context as otelContext, trace, type Tracer } from '@opentelemetry/api';
import type { RequestHandler } from 'express';

import { PropagationPolicy } from './propagationPolicy';
import { completeServerSpan, startServerSpan } from './serverSpan';

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
 * **Host-owned, not plugin-owned, and OUTERMOST** — `loggingMiddleware` runs inside it
 * (runbook D12 as reversed), so the logger reads `trace_id` and `span_id` from the
 * ambient span on every line. Being outside every plugin middleware is the other half of
 * the point: a span created from inside a plugin slot would miss the plugin
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
 *
 * **This is an adapter, and only an adapter.** Span construction lives in `serverSpan.ts`, which
 * knows nothing about HTTP or Express, so the planned gRPC transport arrives as a second adapter
 * rather than a second copy (gate G4).
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

    const { span, propagation: resolved } = startServerSpan({
      tracer,
      method: req.method,
      route: req.path,
      headers: req.headers as Record<string, string>,
      policy,
    });

    res.locals[TRACING_SPAN_LOCAL] = span;
    res.locals[PROPAGATION_RESULT_LOCAL] = resolved;

    let ended = false;
    const endSpan = (aborted: boolean) => {
      if (ended) return;
      ended = true;
      completeServerSpan(span, { statusCode: res.statusCode, aborted });
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
