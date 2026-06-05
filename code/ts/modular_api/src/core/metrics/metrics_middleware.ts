// ============================================================
// core/metrics/metrics_middleware.ts
// Express middleware + handler for Prometheus metrics.
// Zero external dependencies — uses pure metric types.
// ============================================================

import type { RequestHandler } from 'express';
import type { Counter, Gauge, Histogram } from './metric';
import type { MetricRegistry } from './metric_registry';

export interface MetricsMiddlewareOptions {
  requestsTotal: Counter;
  requestsInFlight: Gauge;
  requestDuration: Histogram;
  excludedRoutes: string[];
  registeredPaths: string[];
}

/**
 * Creates an Express middleware that instruments HTTP requests.
 *
 * Records:
 * - `requestsTotal` — counter with labels: method, route, status_code
 * - `requestsInFlight` — gauge (inc on entry, dec on finish)
 * - `requestDuration` — histogram with labels: method, route, status_code
 */
export function metricsMiddleware(opts: MetricsMiddlewareOptions): RequestHandler {
  const excludedSet = new Set(opts.excludedRoutes);
  const registeredSet = new Set(opts.registeredPaths);

  return (req, res, next) => {
    const path = req.path;

    // Skip excluded routes.
    if (excludedSet.has(path)) {
      return next();
    }

    const method = req.method.toUpperCase();
    const route = registeredSet.has(path) ? path : 'UNMATCHED';

    opts.requestsInFlight.inc();
    const startTime = process.hrtime.bigint();

    res.on('finish', () => {
      opts.requestsInFlight.dec();

      const durationNs = Number(process.hrtime.bigint() - startTime);
      const durationSecs = durationNs / 1e9;
      const statusCode = res.statusCode.toString();

      const labels = { method, route, status_code: statusCode };
      opts.requestsTotal.inc(labels);
      opts.requestDuration.observe(labels, durationSecs);
    });

    next();
  };
}

/**
 * Creates an Express handler that returns Prometheus metrics.
 * Always returns HTTP 200 with `text/plain; version=0.0.4; charset=utf-8`.
 */
export function metricsHandler(registry: MetricRegistry): RequestHandler {
  return (_req, res) => {
    const body = registry.serialize();
    res.status(200).set('Content-Type', 'text/plain; version=0.0.4; charset=utf-8').send(body);
  };
}
