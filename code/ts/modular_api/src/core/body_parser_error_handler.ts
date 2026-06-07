// ============================================================
// core/body_parser_error_handler.ts
// Express error middleware — catches SyntaxError from
// express.json() (body-parser) and returns a structured 400
// with scoped-logger warning (trace_id preserved).
//
// Must be mounted immediately after express.json() in serve().
// ============================================================

import type { Request, Response, NextFunction } from 'express';
import { LOGGER_LOCALS_KEY } from './logger/logging_middleware';
import type { ModularLogger } from './logger/logger';

/**
 * Express error-handling middleware for body-parser SyntaxErrors.
 *
 * When `express.json()` encounters malformed JSON, it calls `next(err)`
 * with a `SyntaxError` whose `type` is `'entity.parse.failed'`.
 * This handler intercepts that specific error, logs it through the
 * request-scoped logger (so it carries `trace_id`), and returns a
 * structured 400 response.
 *
 * Any other error is forwarded to the next error handler via `next(err)`.
 */
export function bodyParserErrorHandler(
  err: SyntaxError & { type?: string },
  req: Request,
  res: Response,
  next: NextFunction,
): void {
  if (err instanceof SyntaxError && err.type === 'entity.parse.failed') {
    const logger = res.locals[LOGGER_LOCALS_KEY] as ModularLogger | undefined;
    logger?.warning('Invalid JSON in request body', {
      error: err.message,
      status: 400,
    });
    res.status(400).json({ error: 'Invalid JSON in request body' });
    return;
  }

  next(err);
}
