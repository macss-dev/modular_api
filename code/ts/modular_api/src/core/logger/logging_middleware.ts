// ============================================================
// core/logger/logging_middleware.ts
// Express middleware — trace_id, structured JSON logs.
// Mirror of logging_middleware.dart.
// ============================================================

import { randomUUID } from 'node:crypto';

import { context as otelContext, trace } from '@opentelemetry/api';

import type { RequestHandler } from 'express';
import { LogLevel, RequestScopedLogger, type TraceFieldFormatter } from './logger';
import type { WriteFn } from './logger';
import { ensureRequestPipelineAudit, readShortCircuitCandidate } from '../request_pipeline_audit';

/** Key used in `res.locals` to propagate the logger to downstream handlers. */
export const LOGGER_LOCALS_KEY = 'modularLogger';

export interface LoggingMiddlewareOptions {
  logLevel: LogLevel;
  serviceName: string;
  excludedRoutes?: string[];
  /** Override output for testing. Defaults to stdout. */
  writeFn?: WriteFn;

  /** Builds platform correlation fields. Undefined means none are emitted. */
  traceFieldFormatter?: TraceFieldFormatter;
}

/**
 * Creates an Express middleware that:
 *
 * 1. Reads or generates a `trace_id` (from `X-Request-ID` header).
 * 2. Creates a {@link RequestScopedLogger} scoped to the current request.
 * 3. Emits a `"request received"` log at `info` level.
 * 4. Passes the logger via `res.locals` for downstream handlers.
 * 5. Emits a `"request completed"` log (level based on status code).
 * 6. Returns the `X-Request-ID` header in the response.
 *
 * Requests whose path matches `excludedRoutes` are passed through silently.
 */
export function loggingMiddleware(opts: LoggingMiddlewareOptions): RequestHandler {
  const excludedSet = new Set(opts.excludedRoutes ?? []);

  return (req, res, next) => {
    const path = req.path;

    // Skip excluded routes (health, metrics, docs).
    if (excludedSet.has(path)) {
      return next();
    }

    // 1. Resolve the ids from the ambient span.
    //
    // The tracing middleware is outermost (D12 as reversed), so when tracing is
    // configured a recording span is already active here — and it stays active for
    // `request completed` too. That is what lets both lines carry the same ids with
    // nothing mutated afterwards.
    //
    // With no recording span this is byte-for-byte the behaviour it always had: the
    // caller's X-Request-ID or a fresh UUID. D5b's compatibility guarantee is therefore
    // structural rather than conditional — there is no tracing flag to consult, only
    // whether a span exists.
    const activeSpan = trace.getSpan(otelContext.active());
    const activeSpanContext = activeSpan?.spanContext();
    const tracingActive =
      activeSpanContext !== undefined && trace.isSpanContextValid(activeSpanContext);

    const headerValue = req.headers['x-request-id'];
    const callerRequestId =
      typeof headerValue === 'string' && headerValue.length > 0 ? headerValue : undefined;

    const traceId = tracingActive ? activeSpanContext.traceId : (callerRequestId ?? randomUUID());
    const spanId = tracingActive ? activeSpanContext.spanId : undefined;
    // Preserved beside the trace id rather than promoted into it (D6).
    const requestId = tracingActive ? callerRequestId : undefined;

    // 2. Create per-request logger
    const logger = new RequestScopedLogger(
      traceId,
      opts.logLevel,
      opts.serviceName,
      opts.writeFn,
      requestId,
      spanId,
      opts.traceFieldFormatter,
    );

    const method = req.method.toUpperCase();
    const route = path;

    // 3. "request received"
    logger.logRequest({ method, route });

    // 4. Propagate logger via res.locals
    res.locals[LOGGER_LOCALS_KEY] = logger;
    ensureRequestPipelineAudit(res);

    // 5. Attach X-Request-ID to response
    res.setHeader('X-Request-ID', traceId);

    // 6. Capture timing and emit response log on finish
    const startNs = process.hrtime.bigint();

    res.on('finish', () => {
      const durationMs = Number(process.hrtime.bigint() - startNs) / 1e6;
      const shortCircuit = readShortCircuitCandidate(res);

      logger.logResponse({
        method,
        route,
        statusCode: res.statusCode,
        durationMs,
        extra: shortCircuit
          ? {
              short_circuit: true,
              short_circuit_plugin_id: shortCircuit.pluginId,
              short_circuit_middleware_id: shortCircuit.middlewareId,
              short_circuit_slot: shortCircuit.slot,
            }
          : undefined,
      });
    });

    next();
  };
}
