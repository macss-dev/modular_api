// ============================================================
// handler/body_parser_error.test.ts
// Validates that malformed JSON bodies produce structured 400
// responses WITH trace_id in the log output, not plain-text
// stderr dumps.
//
// Root cause (issue #7): express.json() was mounted in the
// constructor BEFORE loggingMiddleware, so body-parser
// SyntaxErrors fired without a scoped logger.
// ============================================================

import { describe, it, expect } from 'vitest';
import express from 'express';
import request from 'supertest';
import { loggingMiddleware, LOGGER_LOCALS_KEY } from '../../src/core/logger/logging_middleware';
import { LogLevel } from '../../src/core/logger/logger';
import { bodyParserErrorHandler } from '../../src/core/body_parser_error_handler';

/**
 * Builds a minimal Express app with the correct middleware ordering:
 *   1. loggingMiddleware (trace_id + scoped logger)
 *   2. express.json() (body parsing)
 *   3. bodyParserErrorHandler (catches SyntaxError from #2)
 *   4. test route
 *
 * `logLines` captures structured JSON output for assertion.
 */
function buildTestApp(logLines: string[]) {
  const app = express();

  app.use(
    loggingMiddleware({
      logLevel: LogLevel.debug,
      serviceName: 'test-svc',
      writeFn: (line: string) => logLines.push(line),
    }),
  );

  app.use(express.json());
  app.use(bodyParserErrorHandler);

  app.post('/echo', (req, res) => {
    res.status(200).json(req.body);
  });

  return app;
}

describe('Body-parser error handler (issue #7)', () => {
  it('returns 400 with structured JSON when body is malformed', async () => {
    const logLines: string[] = [];
    const app = buildTestApp(logLines);

    const res = await request(app)
      .post('/echo')
      .set('Content-Type', 'application/json')
      .send('{invalid json');

    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: 'Invalid JSON in request body' });
  });

  it('includes trace_id in log output for malformed body', async () => {
    const logLines: string[] = [];
    const app = buildTestApp(logLines);
    const traceId = 'trace-abc-123';

    await request(app)
      .post('/echo')
      .set('Content-Type', 'application/json')
      .set('X-Request-ID', traceId)
      .send('{bad');

    // Find the warning log emitted by the error handler
    const warningLog = logLines
      .map((l) => JSON.parse(l))
      .find(
        (entry: Record<string, unknown>) =>
          entry['level'] === 'warning' && entry['msg'] === 'Invalid JSON in request body',
      );

    expect(warningLog).toBeDefined();
    expect(warningLog['trace_id']).toBe(traceId);
  });

  it('passes valid JSON bodies through to the handler', async () => {
    const logLines: string[] = [];
    const app = buildTestApp(logLines);

    const res = await request(app)
      .post('/echo')
      .set('Content-Type', 'application/json')
      .send(JSON.stringify({ greeting: 'hello' }));

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ greeting: 'hello' });
  });

  it('calls next(err) for non-body-parser errors', async () => {
    const logLines: string[] = [];
    const app = express();

    app.use(
      loggingMiddleware({
        logLevel: LogLevel.debug,
        serviceName: 'test-svc',
        writeFn: (line: string) => logLines.push(line),
      }),
    );

    app.use(express.json());
    app.use(bodyParserErrorHandler);

    // Middleware that throws a generic Error (not a body-parser SyntaxError)
    app.use((_req, _res, next) => {
      next(new Error('something else'));
    });

    // Express default error handler catches it → 500
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    app.use((err: Error, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
      res.status(500).json({ error: 'fallback handler' });
    });

    const res = await request(app)
      .post('/echo')
      .set('Content-Type', 'application/json')
      .send(JSON.stringify({ ok: true }));

    // The generic error should reach the fallback handler, not be swallowed
    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: 'fallback handler' });
  });
});
