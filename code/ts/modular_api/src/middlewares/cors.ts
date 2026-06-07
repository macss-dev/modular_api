// ============================================================
// middlewares/cors.ts
// Simple CORS middleware — no external dependencies.
// Mirror of cors() in Dart.
// ============================================================

import type { RequestHandler } from 'express';

export interface CorsOptions {
  /** Allowed origins. Default: '*' */
  origin?: string | string[];
  /** Allowed methods. Default: 'GET,POST,PUT,PATCH,DELETE,OPTIONS' */
  methods?: string;
  /** Allowed headers. Default: 'Content-Type,Authorization' */
  allowedHeaders?: string;
}

/**
 * Returns an Express middleware that sets CORS headers on every response.
 *
 * Dart equivalent:  api.use(cors())
 * TypeScript:       api.use(cors())
 *
 * Usage:
 * ```ts
 * const api = new ModularApi();
 * api.use(cors());
 * api.use(cors({ origin: 'https://myapp.com' }));
 * ```
 */
export function cors(options: CorsOptions = {}): RequestHandler {
  const origin = Array.isArray(options.origin)
    ? options.origin.join(', ')
    : (options.origin ?? '*');

  const methods = options.methods ?? 'GET,POST,PUT,PATCH,DELETE,OPTIONS';
  const allowedHeaders = options.allowedHeaders ?? 'Content-Type,Authorization';

  return (req, res, next) => {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Access-Control-Allow-Methods', methods);
    res.setHeader('Access-Control-Allow-Headers', allowedHeaders);

    // Respond immediately to pre-flight OPTIONS requests
    if (req.method === 'OPTIONS') {
      res.status(204).end();
      return;
    }

    next();
  };
}
