// ============================================================
// core/health/health_handler.ts
// Express handler for GET /health — application/health+json.
// Mirror of health_handler.dart in Dart.
// ============================================================

import type { RequestHandler } from 'express';
import type { HealthService } from './health_service';

/**
 * Creates an Express request handler that responds to `GET /health`
 * with `application/health+json` following the IETF draft.
 *
 * Returns 200 for pass/warn, 503 for fail.
 */
export function healthHandler(service: HealthService): RequestHandler {
  return async (_req, res) => {
    const response = await service.evaluate();

    res
      .status(response.httpStatusCode)
      .set('Content-Type', 'application/health+json')
      .json(response.toJson());
  };
}
