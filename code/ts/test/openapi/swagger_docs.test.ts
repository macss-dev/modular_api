/**
 * Tests for the docs-ui handler at GET /api/docs.
 *
 * Assertions:
 *   1. GET /docs returns HTTP 200.
 *   2. Content-Type header is text/html; charset=utf-8.
 *   3. Response body contains @macss/docs-ui CDN reference.
 *   4. Response body contains DocsUI.init bootloader call.
 *   5. Response body does NOT contain "scalar" (regression guard).
 */

import { describe, it, expect, afterEach } from 'vitest';
import request from 'supertest';
import type { Server } from 'http';
import { ModularApi } from '../../src';
import { apiRegistry } from '../../src/core/registry';

describe('GET /api/docs — docs-ui (PRD-003)', () => {
  let server: Server;

  afterEach(async () => {
    if (server) {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
    apiRegistry.clear();
  });

  async function startServer(title = 'Test API'): Promise<Server> {
    const api = new ModularApi({ title });
    server = await api.serve({ port: 0 });
    return server;
  }

  it('returns HTTP 200', async () => {
    await startServer();
    const res = await request(server).get('/api/docs');
    expect(res.status).toBe(200);
  });

  it('returns Content-Type text/html', async () => {
    await startServer();
    const res = await request(server).get('/api/docs');
    expect(res.headers['content-type']).toContain('text/html');
  });

  it('body contains @macss/docs-ui CDN reference', async () => {
    await startServer();
    const res = await request(server).get('/api/docs');
    expect(res.text).toContain('@macss/docs-ui');
  });

  it('body contains DocsUI.init bootloader', async () => {
    await startServer();
    const res = await request(server).get('/api/docs');
    expect(res.text).toContain('DocsUI.init');
  });

  it('body contains specUrl pointing to /api/openapi.json', async () => {
    await startServer();
    const res = await request(server).get('/api/docs');
    expect(res.text).toContain('/api/openapi.json');
  });

  it('body does NOT contain scalar (PRD-003 regression guard)', async () => {
    await startServer();
    const res = await request(server).get('/api/docs');
    expect(res.text.toLowerCase()).not.toContain('scalar');
  });

  it('interpolates the API title in the HTML', async () => {
    await startServer('Pet Store');
    const res = await request(server).get('/api/docs');
    expect(res.text).toContain('Pet Store');
  });

  it('returns a complete HTML document', async () => {
    await startServer();
    const res = await request(server).get('/api/docs');
    expect(res.text).toContain('<!DOCTYPE html>');
    expect(res.text).toContain('</html>');
  });

  // ── Dark mode is now handled by @macss/docs-ui — tested in docs-ui/
});
