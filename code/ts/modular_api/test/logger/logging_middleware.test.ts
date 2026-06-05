import { describe, it, expect, beforeEach } from 'vitest';
import express from 'express';
import request from 'supertest';
import { LogLevel } from '../../src/core/logger/logger';
import { loggingMiddleware, LOGGER_LOCALS_KEY } from '../../src/core/logger/logging_middleware';

describe('loggingMiddleware', () => {
  let lines: string[];
  const capture = (line: string) => lines.push(line);

  beforeEach(() => {
    lines = [];
  });

  function createApp(opts?: { logLevel?: LogLevel; excludedRoutes?: string[] }) {
    const app = express();
    app.use(
      loggingMiddleware({
        logLevel: opts?.logLevel ?? LogLevel.debug,
        serviceName: 'test-svc',
        excludedRoutes: opts?.excludedRoutes ?? [],
        writeFn: capture,
      }),
    );
    return app;
  }

  // ─── trace_id ──────────────────────────────────────────────────────

  describe('trace_id', () => {
    it('generates a UUID v4 when X-Request-ID header is absent', async () => {
      const app = createApp();
      app.get('/api/test', (_req, res) => res.json({ ok: true }));

      await request(app).get('/api/test');

      expect(lines.length).toBeGreaterThanOrEqual(2);
      const first = JSON.parse(lines[0]);
      expect(first.trace_id).toMatch(
        /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
      );
    });

    it('uses X-Request-ID header value when present', async () => {
      const app = createApp();
      app.post('/api/test', (_req, res) => res.json({ ok: true }));

      await request(app).post('/api/test').set('X-Request-ID', 'custom-trace-abc');

      const first = JSON.parse(lines[0]);
      expect(first.trace_id).toBe('custom-trace-abc');
    });

    it('same trace_id is used in both request and response logs', async () => {
      const app = createApp();
      app.get('/api/check', (_req, res) => res.json({ ok: true }));

      await request(app).get('/api/check');

      expect(lines.length).toBe(2);
      const reqLog = JSON.parse(lines[0]);
      const resLog = JSON.parse(lines[1]);
      expect(reqLog.trace_id).toBe(resLog.trace_id);
    });

    it('X-Request-ID response header contains the used trace_id', async () => {
      const app = createApp();
      app.get('/api/test', (_req, res) => res.json({ ok: true }));

      const resp = await request(app).get('/api/test');

      expect(resp.headers['x-request-id']).toBeTruthy();
      const first = JSON.parse(lines[0]);
      expect(resp.headers['x-request-id']).toBe(first.trace_id);
    });
  });

  // ─── request received log ──────────────────────────────────────────

  describe('request received log', () => {
    it('emits "request received" as first log with info level', async () => {
      const app = createApp();
      app.post('/api/users/create', (_req, res) => res.json({ ok: true }));

      await request(app).post('/api/users/create');

      const first = JSON.parse(lines[0]);
      expect(first.msg).toBe('request received');
      expect(first.level).toBe('info');
      expect(first.severity).toBe(6);
    });

    it('includes method and route fields', async () => {
      const app = createApp();
      app.post('/api/users/create', (_req, res) => res.json({ ok: true }));

      await request(app).post('/api/users/create');

      const first = JSON.parse(lines[0]);
      expect(first.method).toBe('POST');
      expect(first.route).toBe('/api/users/create');
    });

    it('includes service name', async () => {
      const app = createApp();
      app.get('/api/test', (_req, res) => res.json({ ok: true }));

      await request(app).get('/api/test');

      const first = JSON.parse(lines[0]);
      expect(first.service).toBe('test-svc');
    });
  });

  // ─── request completed log ─────────────────────────────────────────

  describe('request completed log', () => {
    it('emits "request completed" with status and duration_ms', async () => {
      const app = createApp();
      app.get('/api/test', (_req, res) => res.json({ ok: true }));

      await request(app).get('/api/test');

      const last = JSON.parse(lines[lines.length - 1]);
      expect(last.msg).toBe('request completed');
      expect(last.status).toBe(200);
      expect(typeof last.duration_ms).toBe('number');
      expect(last.duration_ms).toBeGreaterThanOrEqual(0);
    });

    it('includes method and route', async () => {
      const app = createApp();
      app.put('/api/items/update', (_req, res) => res.json({ ok: true }));

      await request(app).put('/api/items/update');

      const last = JSON.parse(lines[lines.length - 1]);
      expect(last.method).toBe('PUT');
      expect(last.route).toBe('/api/items/update');
    });
  });

  // ─── status code → log level ───────────────────────────────────────

  describe('status code to log level mapping', () => {
    it('2xx → info', async () => {
      const app = createApp();
      app.post('/api/test', (_req, res) => res.status(201).json({}));

      await request(app).post('/api/test');

      const last = JSON.parse(lines[lines.length - 1]);
      expect(last.level).toBe('info');
    });

    it('400 → warning', async () => {
      const app = createApp();
      app.post('/api/test', (_req, res) => res.status(400).json({}));

      await request(app).post('/api/test');

      const last = JSON.parse(lines[lines.length - 1]);
      expect(last.level).toBe('warning');
    });

    it('404 → warning', async () => {
      const app = createApp();
      app.get('/api/missing', (_req, res) => res.status(404).json({}));

      await request(app).get('/api/missing');

      const last = JSON.parse(lines[lines.length - 1]);
      expect(last.level).toBe('warning');
    });

    it('500 → error', async () => {
      const app = createApp();
      app.post('/api/test', (_req, res) => res.status(500).json({}));

      await request(app).post('/api/test');

      const last = JSON.parse(lines[lines.length - 1]);
      expect(last.level).toBe('error');
    });

    it('503 → error', async () => {
      const app = createApp();
      app.post('/api/test', (_req, res) => res.status(503).json({}));

      await request(app).post('/api/test');

      const last = JSON.parse(lines[lines.length - 1]);
      expect(last.level).toBe('error');
    });
  });

  // ─── excluded routes ───────────────────────────────────────────────

  describe('excluded routes', () => {
    it('/health is not logged when excluded', async () => {
      const app = createApp({ excludedRoutes: ['/health', '/metrics'] });
      app.get('/health', (_req, res) => res.send('ok'));

      await request(app).get('/health');

      expect(lines.length).toBe(0);
    });

    it('/metrics is not logged when excluded', async () => {
      const app = createApp({ excludedRoutes: ['/health', '/metrics'] });
      app.get('/metrics', (_req, res) => res.send('ok'));

      await request(app).get('/metrics');

      expect(lines.length).toBe(0);
    });

    it('non-excluded routes are logged normally', async () => {
      const app = createApp({ excludedRoutes: ['/health', '/metrics'] });
      app.post('/api/users/create', (_req, res) => res.json({ ok: true }));

      await request(app).post('/api/users/create');

      expect(lines.length).toBe(2);
    });
  });

  // ─── logger propagation ────────────────────────────────────────────

  describe('logger propagation via res.locals', () => {
    it('logger is available in res.locals', async () => {
      const app = createApp();
      let captured: unknown = undefined;
      app.get('/api/test', (_req, res) => {
        captured = res.locals[LOGGER_LOCALS_KEY];
        res.json({ ok: true });
      });

      await request(app).get('/api/test');

      expect(captured).toBeTruthy();
    });

    it('logger has the correct trace_id', async () => {
      const app = createApp();
      let traceId = '';
      app.get('/api/test', (_req, res) => {
        const logger = res.locals[LOGGER_LOCALS_KEY];
        traceId = logger.traceId;
        res.json({ ok: true });
      });

      await request(app).get('/api/test').set('X-Request-ID', 'my-trace');

      expect(traceId).toBe('my-trace');
    });
  });
});
