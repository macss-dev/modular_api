import { describe, expect, it } from 'vitest';

import { HOST_API_VERSION, ModularApi, PluginHostError, type HostMetadata, type Plugin, type PluginHost, type PluginManifest } from '../../src';

describe('Plugin host lifecycle', () => {
  it('does not run setup during registration', () => {
    const plugin = new RecordingPlugin('acme.lifecycle');
    const api = new ModularApi({ basePath: '/api', title: 'Lifecycle API', version: '1.2.3' });

    api.plugin(plugin);

    expect(plugin.setupCalls).toBe(0);
    expect(plugin.observedMetadata).toBeUndefined();
  });

  it('runs setup during serve and exposes host metadata', async () => {
    const plugin = new RecordingPlugin('acme.lifecycle');
    const api = new ModularApi({ basePath: '/api', title: 'Lifecycle API', version: '1.2.3' }).plugin(plugin);

    const server = await api.serve({ port: 0 });
    try {
      expect(plugin.setupCalls).toBe(1);
      expect(plugin.observedMetadata).toEqual({
        basePath: '/api',
        title: 'Lifecycle API',
        version: '1.2.3',
        hostApiVersion: HOST_API_VERSION,
      });
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

  it('fails startup on duplicate plugin ids', async () => {
    const api = new ModularApi({ basePath: '/api' })
      .plugin(new RecordingPlugin('acme.duplicate'))
      .plugin(new RecordingPlugin('acme.duplicate'));

    await expect(api.serve({ port: 0 })).rejects.toThrowError(PluginHostError);
    await expect(api.serve({ port: 0 })).rejects.toThrow(/PLUGIN_ID_CONFLICT|Duplicate plugin id/);
  });

  it('orders setup by plugin dependencies and preserves registration order as tiebreaker', async () => {
    const events: string[] = [];
    const api = new ModularApi({ basePath: '/api' })
      .plugin(new DependentPlugin('acme.child-b', 'acme.root', events))
      .plugin(new DependentPlugin('acme.child-a', 'acme.root', events))
      .plugin(new RecordingPlugin('acme.root', events));

    const server = await api.serve({ port: 0 });
    try {
      expect(events).toEqual([
        'setup:acme.root',
        'setup:acme.child-b',
        'setup:acme.child-a',
      ]);
    } finally {
      await closeServer(server);
    }
  });

  it('runs plugin validation after setup and aborts startup on blocking validation', async () => {
    const plugin = new InvalidatingPlugin('acme.invalid');
    const api = new ModularApi({ basePath: '/api' }).plugin(plugin);

    await expect(api.serve({ port: 0 })).rejects.toThrow(/PLUGIN_VALIDATION_FAILED|invalid plugin/);
    expect(plugin.setupCalls).toBe(1);
    expect(plugin.validateCalls).toBe(1);
  });

  it('runs shutdown in reverse setup order', async () => {
    const events: string[] = [];
    const api = new ModularApi({ basePath: '/api' })
      .plugin(new ShutdownPlugin('acme.child', events, 'acme.root'))
      .plugin(new ShutdownPlugin('acme.root', events));

    const server = await api.serve({ port: 0 });
    await closeServer(server);

    expect(events).toEqual([
      'setup:acme.root',
      'setup:acme.child',
      'shutdown:acme.child',
      'shutdown:acme.root',
    ]);
  });

  it('runs shutdown for already setup plugins when validation aborts startup', async () => {
    const events: string[] = [];
    const api = new ModularApi({ basePath: '/api' })
      .plugin(new ShutdownPlugin('acme.root', events))
      .plugin(new FailingShutdownPlugin('acme.invalid', events));

    await expect(api.serve({ port: 0 })).rejects.toThrow(/PLUGIN_VALIDATION_FAILED|invalid plugin/);
    expect(events).toEqual([
      'setup:acme.root',
      'setup:acme.invalid',
      'shutdown:acme.invalid',
      'shutdown:acme.root',
    ]);
  });

  it('rejects late host registration after startup freeze', async () => {
    const plugin = new LateRegistrationPlugin('acme.late');
    const api = new ModularApi({ basePath: '/api' }).plugin(plugin);

    const server = await api.serve({ port: 0 });
    try {
      expect(() => plugin.registerLateRoute()).toThrowError(PluginHostError);
      expect(() => plugin.registerLateRoute()).toThrow(/PLUGIN_VALIDATION_FAILED|frozen/);
    } finally {
      await closeServer(server);
    }
  });
});

class RecordingPlugin implements Plugin {
  setupCalls = 0;
  observedMetadata: HostMetadata | undefined;

  readonly manifest: PluginManifest;

  constructor(id: string, private readonly events?: string[]) {
    this.manifest = {
      id,
      displayName: 'Recording Plugin',
      version: '0.1.0',
      hostApiVersion: '>=0.1.0 <0.2.0',
    };
  }

  setup(host: PluginHost): void {
    this.setupCalls += 1;
    this.observedMetadata = host.metadata();
    this.events?.push(`setup:${this.manifest.id}`);
  }
}

class DependentPlugin extends RecordingPlugin {
  constructor(id: string, dependencyId: string, events: string[]) {
    super(id, events);
    this.manifest.requires = [{ type: 'plugin', id: dependencyId }];
  }
}

class InvalidatingPlugin extends RecordingPlugin {
  validateCalls = 0;

  validate(): Array<{ code: string; message: string; pluginId: string }> {
    this.validateCalls += 1;
    return [
      {
        code: 'PLUGIN_VALIDATION_FAILED',
        message: 'invalid plugin',
        pluginId: this.manifest.id,
      },
    ];
  }
}

class ShutdownPlugin extends RecordingPlugin {
  constructor(id: string, events: string[], dependencyId?: string) {
    super(id, events);
    if (dependencyId) {
      this.manifest.requires = [{ type: 'plugin', id: dependencyId }];
    }
  }

  shutdown(): void {
    this.events?.push(`shutdown:${this.manifest.id}`);
  }
}

class FailingShutdownPlugin extends ShutdownPlugin {
  validate() {
    return [
      {
        code: 'PLUGIN_VALIDATION_FAILED',
        message: 'invalid plugin',
        pluginId: this.manifest.id,
      },
    ];
  }
}

class LateRegistrationPlugin extends RecordingPlugin {
  private host: PluginHost | undefined;

  setup(host: PluginHost): void {
    super.setup(host);
    this.host = host;
  }

  registerLateRoute(): void {
    this.host?.registerRoute({
      id: 'late-route',
      method: 'GET',
      path: '/late',
      visibility: 'custom',
      handler: () => ({ status: 200, body: { ok: true } }),
    });
  }
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