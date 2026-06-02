import express from 'express';
import request from 'supertest';
import { describe, expect, it } from 'vitest';

import { Input, Output, type Plugin, type PluginHost, type PluginManifest, type PluginMiddleware, type UseCase } from '../../src';
import { bodyParserErrorHandler } from '../../src/core/body_parser_error_handler';
import { LogLevel } from '../../src/core/logger/logger';
import { loggingMiddleware } from '../../src/core/logger/logging_middleware';
import { RuntimePluginHost } from '../../src/core/plugin';
import { useCaseHandler } from '../../src/core/usecase_handler';
import { unhandledRequestErrorHandler } from '../../src/core/unhandled_request_error_handler';

describe('Plugin middleware guardrails', () => {
  it('annotates the completed request log when plugin middleware short-circuits before the core handler', async () => {
    const events: string[] = [];
    const logLines: string[] = [];
    const app = buildGuardrailApp({
      logLines,
      events,
      plugins: [
        new MiddlewarePlugin('acme.guard', [
          {
            id: 'auth',
            slot: 'preHandler',
            order: 0,
            handler: (_req, res) => {
              res.status(401).json({ error: 'blocked by plugin' });
            },
          },
        ]),
      ],
    });

    const response = await request(app)
      .post('/api/demo/pipeline')
      .set('X-Request-ID', 'trace-ts-short-circuit')
      .send({ name: 'Ada' });

    expect(response.status).toBe(401);
    expect(response.body).toEqual({ error: 'blocked by plugin' });
    expect(events).toEqual([]);

    const completedLog = JSON.parse(logLines[logLines.length - 1]) as Record<string, unknown>;
    expect(completedLog.msg).toBe('request completed');
    expect(completedLog.trace_id).toBe('trace-ts-short-circuit');
    expect(completedLog.short_circuit).toBe(true);
    expect(completedLog.short_circuit_plugin_id).toBe('acme.guard');
    expect(completedLog.short_circuit_middleware_id).toBe('acme.guard.auth');
    expect(completedLog.short_circuit_slot).toBe('preHandler');
  });

  it('returns a normalized 500 JSON response when plugin middleware throws outside the core handler', async () => {
    const events: string[] = [];
    const logLines: string[] = [];
    const app = buildGuardrailApp({
      logLines,
      events,
      plugins: [
        new MiddlewarePlugin('acme.guard', [
          {
            id: 'boom',
            slot: 'preHandler',
            order: 0,
            handler: () => {
              throw new Error('boom');
            },
          },
        ]),
      ],
    });

    const response = await request(app)
      .post('/api/demo/pipeline')
      .set('X-Request-ID', 'trace-ts-error-guardrail')
      .send({ name: 'Ada' });

    expect(response.status).toBe(500);
    expect(response.body).toEqual({ error: 'Internal server error' });
    expect(events).toEqual([]);

    const parsedLogs = logLines.map((line) => JSON.parse(line) as Record<string, unknown>);
    const errorLog = parsedLogs.find((line) => line.msg === 'Unhandled error in request pipeline');
    expect(errorLog).toMatchObject({
      trace_id: 'trace-ts-error-guardrail',
      level: 'error',
      fields: { status: 500, error: 'Error: boom' },
    });

    const completedLog = parsedLogs[parsedLogs.length - 1];
    expect(completedLog.msg).toBe('request completed');
    expect(completedLog.status).toBe(500);
    expect(completedLog.short_circuit).toBeUndefined();
  });
});

function buildGuardrailApp(options: {
  plugins: Plugin[];
  events: string[];
  logLines: string[];
}) {
  const app = express();
  const host = new RuntimePluginHost({
    basePath: '/api',
    title: 'Guardrail Test API',
    version: '0.1.0',
  });

  for (const plugin of options.plugins) {
    host.beginPluginSetup(plugin.manifest.id);
    plugin.setup(host);
    host.endPluginSetup();
  }

  host.freeze();
  host.assertValid();

  app.use(
    loggingMiddleware({
      logLevel: LogLevel.debug,
      serviceName: 'guardrail-test',
      writeFn: (line) => options.logLines.push(line),
    }),
  );
  app.use(express.json());
  app.use(bodyParserErrorHandler);

  host.applyMiddlewares('preRouting', app);
  host.applyMiddlewares('preHandler', app);
  host.applyMiddlewares('postHandler', app);

  app.post(
    '/api/demo/pipeline',
    useCaseHandler((json) => new GuardrailUseCase(GuardrailInput.fromJson(json), options.events), {
      inputClass: GuardrailInput,
    }),
  );

  app.use(unhandledRequestErrorHandler);
  return app;
}

class GuardrailInput extends Input {
  constructor(public name = '') {
    super();
  }

  static fromJson(json: Record<string, unknown>): GuardrailInput {
    return new GuardrailInput(typeof json.name === 'string' ? json.name : '');
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

class GuardrailOutput extends Output {
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

class GuardrailUseCase implements UseCase<GuardrailInput, GuardrailOutput> {
  logger = undefined;

  constructor(
    readonly input: GuardrailInput,
    private readonly events: string[],
  ) {}

  validate(): string | null {
    this.events.push('validate');
    return null;
  }

  async execute(): Promise<GuardrailOutput> {
    this.events.push('execute');
    return new GuardrailOutput(`Hello, ${this.input.name}`);
  }
}

class MiddlewarePlugin implements Plugin {
  readonly manifest: PluginManifest;

  constructor(
    id: string,
    private readonly definitions: Array<{
      id: string;
      slot: PluginMiddleware['slot'];
      order: number;
      handler: PluginMiddleware['handler'];
    }>,
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
        slot: definition.slot,
        order: definition.order,
        handler: definition.handler,
      });
    }
  }
}