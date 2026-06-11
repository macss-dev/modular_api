import { describe, expect, it } from 'vitest';
import request from 'supertest';

import { HOST_API_VERSION, ModularApi } from '../../src';
import type { Plugin, RegisteredPluginRouteView } from '../../src';

// ADR-0003: plugin routes are first-class in OpenAPI and metrics.

function buildBinaryPlugin(): Plugin {
  return {
    manifest: {
      id: 'test.binary',
      displayName: 'Test Binary Plugin',
      version: '1.0.0',
      hostApiVersion: HOST_API_VERSION,
    },
    setup(host) {
      host.registerRoute({
        id: 'binary.foto.get',
        method: 'GET',
        path: '/binarios/foto',
        visibility: 'custom',
        openapi: {
          summary: 'Devuelve el binario de una foto',
          parameters: [{ name: 'nombre', in: 'query', required: true, schema: { type: 'string' } }],
          responses: {
            '200': {
              description: 'Foto encontrada',
              content: { 'image/jpeg': { schema: { type: 'string', format: 'binary' } } },
            },
            '404': { description: 'Foto no encontrada' },
          },
        },
        handler: () => ({
          status: 200,
          contentType: 'image/jpeg',
          body: Buffer.from([0xff, 0xd8, 0xff, 0xe0]),
        }),
      });

      host.registerRoute({
        id: 'binary.sin-doc.get',
        method: 'GET',
        path: '/binarios/sin-doc',
        visibility: 'custom',
        handler: () => ({ status: 200, body: 'ok' }),
      });
    },
  };
}

async function closeServer(server: import('http').Server): Promise<void> {
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

describe('Plugin OpenAPI contributions (ADR-0003)', () => {
  it('documents plugin routes that declare an openapi operation', async () => {
    const api = new ModularApi({ basePath: '/api', title: 'ADR3', version: '1.0.0' });
    api.plugin(buildBinaryPlugin());

    const server = await api.serve({ port: 0 });
    try {
      const spec = await request(server).get('/api/openapi.json');
      expect(spec.status).toBe(200);

      const operation = spec.body.paths?.['/api/binarios/foto']?.get;
      expect(operation).toBeDefined();
      expect(operation.summary).toBe('Devuelve el binario de una foto');
      expect(operation.responses['200'].content['image/jpeg'].schema.format).toBe('binary');
    } finally {
      await closeServer(server);
    }
  });

  it('does not document plugin routes without an openapi operation, nor operational routes', async () => {
    const api = new ModularApi({ basePath: '/api', title: 'ADR3', version: '1.0.0' });
    api.plugin(buildBinaryPlugin());

    const server = await api.serve({ port: 0 });
    try {
      const spec = await request(server).get('/api/openapi.json');
      expect(spec.status).toBe(200);

      const paths = spec.body.paths ?? {};
      expect(paths['/api/binarios/sin-doc']).toBeUndefined();
      expect(paths['/api/health']).toBeUndefined();
      expect(paths['/api/openapi.json']).toBeUndefined();
    } finally {
      await closeServer(server);
    }
  });

  it('exposes registered plugin routes through the host routes() view', async () => {
    let captured: RegisteredPluginRouteView[] = [];

    const observer: Plugin = {
      manifest: {
        id: 'test.observer',
        displayName: 'Test Observer Plugin',
        version: '1.0.0',
        hostApiVersion: HOST_API_VERSION,
      },
      setup() {
        /* sin rutas */
      },
      validate(host) {
        captured = host.routes();
        return [];
      },
    };

    const api = new ModularApi({ basePath: '/api', title: 'ADR3', version: '1.0.0' });
    api.plugin(buildBinaryPlugin());
    api.plugin(observer);

    const server = await api.serve({ port: 0 });
    try {
      const fotoRoute = captured.find((route) => route.path === '/api/binarios/foto');
      expect(fotoRoute).toBeDefined();
      expect(fotoRoute?.pluginId).toBe('test.binary');
      expect(fotoRoute?.method).toBe('GET');
      expect(fotoRoute?.visibility).toBe('custom');
      expect(fotoRoute?.openapi?.summary).toBe('Devuelve el binario de una foto');
    } finally {
      await closeServer(server);
    }
  });

  it('labels plugin routes with their real path in http_requests_total (not UNMATCHED)', async () => {
    const api = new ModularApi({
      basePath: '/api',
      title: 'ADR3',
      version: '1.0.0',
      metricsEnabled: true,
    });
    api.plugin(buildBinaryPlugin());

    const server = await api.serve({ port: 0 });
    try {
      await request(server).get('/api/binarios/foto').expect(200);
      await request(server).get('/api/binarios/foto').expect(200);

      const metrics = await request(server).get('/api/metrics');
      expect(metrics.status).toBe(200);
      expect(metrics.text).toContain('route="/api/binarios/foto"');
      expect(metrics.text).not.toMatch(/route="UNMATCHED"[^\n]*status_code="200"/);
    } finally {
      await closeServer(server);
    }
  });
});
