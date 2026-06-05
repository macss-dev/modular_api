import { describe, expect, it } from 'vitest';
import request from 'supertest';

import { ModularApi } from '../../src';

describe('Official plugins under shared basePath', () => {
  it('serves operational endpoints under /api only', async () => {
    const api = new ModularApi({
      basePath: '/api',
      title: 'Plugin Ops',
      version: '1.0.0',
      metricsEnabled: true,
    });

    const server = await api.serve({ port: 0 });
    try {
      const health = await request(server).get('/api/health');
      expect(health.status).toBe(200);
      expect(health.body.status).toBe('pass');

      const metrics = await request(server).get('/api/metrics');
      expect(metrics.status).toBe(200);
      expect(metrics.text).toContain('http_requests_total');

      const openApiJson = await request(server).get('/api/openapi.json');
      expect(openApiJson.status).toBe(200);
      expect(openApiJson.body.openapi).toBe('3.0.0');

      const openApiYaml = await request(server).get('/api/openapi.yaml');
      expect(openApiYaml.status).toBe(200);
      expect(openApiYaml.text).toContain('openapi: 3.0.0');

      const docs = await request(server).get('/api/docs');
      expect(docs.status).toBe(200);
      expect(docs.text).toContain('/api/openapi.json');

      await request(server).get('/health').expect(404);
      await request(server).get('/metrics').expect(404);
      await request(server).get('/openapi.json').expect(404);
      await request(server).get('/openapi.yaml').expect(404);
      await request(server).get('/docs').expect(404);
    } finally {
      await new Promise<void>((resolve, reject) => {
        server.close((error) => {
          if (error) {
            reject(error);
            return;
          }

          resolve();
        });
      });
    }
  });
});