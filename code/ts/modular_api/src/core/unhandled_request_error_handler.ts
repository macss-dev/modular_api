import type { ErrorRequestHandler } from 'express';

import { LOGGER_LOCALS_KEY } from './logger/logging_middleware';
import type { ModularLogger } from './logger/logger';

export const unhandledRequestErrorHandler: ErrorRequestHandler = (error, _req, res, next) => {
  if (res.headersSent) {
    next(error);
    return;
  }

  const logger = res.locals[LOGGER_LOCALS_KEY] as ModularLogger | undefined;
  logger?.error('Unhandled error in request pipeline', {
    error: String(error),
    status: 500,
  });

  res.status(500).json({ error: 'Internal server error' });
};