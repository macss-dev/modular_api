import { describe, expect, it } from 'vitest';
import request from 'supertest';
import {
  ModularApi,
  type Plugin,
  type PluginHost,
  type PluginManifest,
} from '../../src';

describe('Stage 0 red baseline - plugin host', () => {
  it('exposes plugin registration and public plugin types', () => {
    const api = new ModularApi({ basePath: '/api' });
    const plugin = new ProbePlugin();

    expect(api.plugin(plugin)).toBe(api);
    expect(plugin.manifest.id).toBe('acme.echo');
  });

  it('mounts plugin routes only under the shared basePath', async () => {
    const api = new ModularApi({ basePath: '/api' }).plugin(new ProbePlugin());
    const server = await api.serve({ port: 0 });

    try {
      await request(server).get('/api/plugin-probe').expect(200);
      await request(server).get('/plugin-probe').expect(404);
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

class ProbePlugin implements Plugin {
  readonly manifest: PluginManifest = {
    id: 'acme.echo',
    displayName: 'Echo Probe',
    version: '0.1.0',
    hostApiVersion: '>=0.1.0 <0.2.0',
  };

  setup(host: PluginHost): void {
    host.registerRoute({
      id: 'probe-route',
      method: 'GET',
      path: '/plugin-probe',
      visibility: 'custom',
      handler: () => ({ status: 200, body: { ok: true } }),
    });
  }
}