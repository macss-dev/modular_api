import request from 'supertest';
import { describe, expect, it } from 'vitest';

import {
  Input,
  LOGGER_LOCALS_KEY,
  ModularApi,
  Output,
  PluginHostError,
  type Plugin,
  type PluginHost,
  type PluginManifest,
  type PluginMiddleware,
  type PluginRequestContext,
  type UseCase,
} from '../../src';

describe('Plugin middleware slots', () => {
  it('orders middleware by slot, order, and setup order without bypassing the use case lifecycle', async () => {
    const events: string[] = [];
    const api = new ModularApi({ basePath: '/api', title: 'Stage 4 API' })
      .plugin(
        new MiddlewarePlugin('acme.first', events, [
          recordingMiddlewareDefinition('preHandler:first', 'preHandler', 5, events),
        ]),
      )
      .plugin(
        new MiddlewarePlugin('acme.second', events, [
          recordingMiddlewareDefinition('preHandler:second', 'preHandler', 5, events),
        ]),
      )
      .plugin(
        new MiddlewarePlugin('acme.low', events, [
          loggingProbeMiddlewareDefinition(events),
          recordingMiddlewareDefinition('preHandler:low', 'preHandler', 1, events),
          recordingMiddlewareDefinition('postHandler:low', 'postHandler', 0, events),
        ]),
      )
      .use((_req, _res, next) => {
        events.push('custom');
        next();
      });

    api.module('demo', (m) => {
      m.usecase(
        'pipeline',
        (json) => new Stage4UseCase(Stage4Input.fromJson(json), events),
        {
          inputClass: Stage4Input,
          outputClass: Stage4Output,
        },
      );
    });

    const server = await api.serve({ port: 0 });
    try {
      const response = await request(server)
        .post('/api/demo/pipeline')
        .set('X-Request-ID', 'trace-stage4-order')
        .send({ name: 'Ada' });

      expect(response.status).toBe(200);
      expect(events).toEqual([
        'preRouting:logger',
        'custom',
        'preHandler:low',
        'preHandler:first',
        'preHandler:second',
        'postHandler:low',
        'validate',
        'execute',
      ]);
    } finally {
      await closeServer(server);
    }
  });

  it('rejects unknown middleware slots during startup', async () => {
    const api = new ModularApi({ basePath: '/api' }).plugin(
      new MiddlewarePlugin('acme.invalid', [], [
        recordingMiddlewareDefinition('invalid', 'moonPhase', 0, []),
      ]),
    );

    await expect(api.serve({ port: 0 })).rejects.toThrowError(PluginHostError);
    await expect(api.serve({ port: 0 })).rejects.toThrow(/PLUGIN_VALIDATION_FAILED|Unknown middleware slot/);
  });

  it('passes a full request context to plugin route handlers', async () => {
    const api = new ModularApi({ basePath: '/api' }).plugin(new ContextRoutePlugin());

    const server = await api.serve({ port: 0 });
    try {
      const response = await request(server)
        .post('/api/plugin-context/alice?lang=ts')
        .set('X-Request-ID', 'trace-stage4-context')
        .set('X-Stage4', 'present')
        .send({ hello: 'world' });

      expect(response.status).toBe(200);
      expect(response.body).toEqual({
        requestId: 'trace-stage4-context',
        loggerPresent: true,
        method: 'POST',
        path: '/api/plugin-context/alice',
        stageHeader: 'present',
        queryLang: 'ts',
        bodyHello: 'world',
        pathName: 'alice',
        capabilityIds: expect.arrayContaining(['acme.capability']),
      });
    } finally {
      await closeServer(server);
    }
  });
});

class Stage4Input extends Input {
  constructor(public name = '') {
    super();
  }

  static fromJson(json: Record<string, unknown>): Stage4Input {
    return new Stage4Input(typeof json.name === 'string' ? json.name : '');
  }

  override toJson(): Record<string, unknown> {
    return { name: this.name };
  }

  override toSchema(): Record<string, unknown> {
    return {
      type: 'object',
      properties: {
        name: { type: 'string' },
      },
      required: ['name'],
    };
  }
}

class Stage4Output extends Output {
  constructor(public message = 'ok') {
    super();
  }

  override get statusCode(): number {
    return 200;
  }

  override toJson(): Record<string, unknown> {
    return { message: this.message };
  }

  override toSchema(): Record<string, unknown> {
    return {
      type: 'object',
      properties: {
        message: { type: 'string' },
      },
      required: ['message'],
    };
  }
}

class Stage4UseCase implements UseCase<Stage4Input, Stage4Output> {
  logger = undefined;

  constructor(
    readonly input: Stage4Input,
    private readonly events: string[],
  ) {}

  validate(): string | null {
    this.events.push('validate');
    return null;
  }

  async execute(): Promise<Stage4Output> {
    this.events.push('execute');
    return new Stage4Output(`Hello, ${this.input.name}`);
  }
}

interface MiddlewareDefinition {
  id: string;
  slot: string;
  order: number;
  handler: PluginMiddleware['handler'];
}

class MiddlewarePlugin implements Plugin {
  readonly manifest: PluginManifest;

  constructor(
    id: string,
    private readonly events: string[],
    private readonly definitions: MiddlewareDefinition[],
  ) {
    this.manifest = {
      id,
      displayName: 'Middleware Plugin',
      version: '0.1.0',
      hostApiVersion: '>=0.1.0 <0.2.0',
    };
  }

  setup(host: PluginHost): void {
    for (const definition of this.definitions) {
      host.registerMiddleware({
        id: `${this.manifest.id}.${definition.id}`,
        slot: definition.slot as PluginMiddleware['slot'],
        order: definition.order,
        handler: definition.handler,
      });
    }
  }
}

class ContextRoutePlugin implements Plugin {
  readonly manifest: PluginManifest = {
    id: 'acme.context',
    displayName: 'Context Plugin',
    version: '0.1.0',
    hostApiVersion: '>=0.1.0 <0.2.0',
  };

  setup(host: PluginHost): void {
    host.exposeCapability({
      id: 'acme.capability',
      version: '1.0.0',
      value: { ok: true },
    });

    host.registerRoute({
      id: 'plugin-context',
      method: 'POST',
      path: '/plugin-context/:name',
      visibility: 'custom',
      handler: (context: PluginRequestContext) => ({
        status: 200,
        body: {
          requestId: context.requestId,
          loggerPresent: Boolean(context.logger),
          method: context.method,
          path: context.path,
          stageHeader: context.headers['x-stage4'],
          queryLang: context.query.lang,
          bodyHello: (context.body as { hello?: string } | undefined)?.hello,
          pathName: context.pathParams.name,
          capabilityIds: Array.from(context.capabilities().keys()),
        },
      }),
    });
  }
}

function loggingProbeMiddlewareDefinition(events: string[]): MiddlewareDefinition {
  return {
    id: 'preRouting.logger',
    slot: 'preRouting',
    order: 0,
    handler: (_req, res, next) => {
      events.push(res.locals[LOGGER_LOCALS_KEY] ? 'preRouting:logger' : 'preRouting:no-logger');
      next();
    },
  };
}

function recordingMiddlewareDefinition(
  label: string,
  slot: string,
  order: number,
  events: string[],
): MiddlewareDefinition {
  return {
    id: label,
    slot,
    order,
    handler: (_req, _res, next) => {
      events.push(label);
      next();
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