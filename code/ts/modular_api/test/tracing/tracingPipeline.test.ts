import { InMemorySpanExporter, SimpleSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { NodeTracerProvider } from '@opentelemetry/sdk-trace-node';
import type { Server } from 'node:http';
import request from 'supertest';
import { afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { Input, ModularApi, Output, TracingOptions, UseCase } from '../../src';

/**
 * The full pipeline, through a real request.
 *
 * TypeScript mirror of `test/tracing/tracing_pipeline_test.dart`. The middleware tests exercise
 * `tracingMiddleware` directly; this exercises what `ModularApi.serve()` actually assembles, which is
 * the only thing that can catch the host wiring the middleware in the wrong place or not at all.
 *
 * **The G3 group is why this file was added at the merge gate.** Dart asserted the structural half of
 * G3 — that absent `tracing` means nothing is installed, not "installed and idle" — through a real
 * request. TypeScript and Python asserted G3 only at the middleware and satellite level, so the host's
 * conditional was never exercised in either. D1 says a stage advances all three; this one had not.
 */
class PingInput implements Input {
  toJson() {
    return {};
  }
  toSchema() {
    return { type: 'object', properties: {} };
  }
}

class PingOutput implements Output {
  get statusCode() {
    return 200;
  }
  toJson() {
    return { echo: 'ping' };
  }
  toSchema() {
    return { type: 'object', properties: { echo: { type: 'string' } } };
  }
}

class PingUseCase extends UseCase<PingInput, PingOutput> {
  readonly input: PingInput;

  constructor(input: PingInput) {
    super();
    this.input = input;
  }

  static fromJson(_json: Record<string, unknown>) {
    return new PingUseCase(new PingInput());
  }

  validate() {
    return null;
  }

  async execute() {
    return new PingOutput();
  }
}

const exporter = new InMemorySpanExporter();
let provider: NodeTracerProvider;

beforeAll(() => {
  provider = new NodeTracerProvider({ spanProcessors: [new SimpleSpanProcessor(exporter)] });
  provider.register();
});

beforeEach(() => exporter.reset());

let server: Server | undefined;

afterEach(async () => {
  if (server === undefined) return;
  const closing = server;
  server = undefined;
  await new Promise<void>((resolve, reject) =>
    closing.close((error) => (error ? reject(error) : resolve())),
  );
});

function apiWith(tracing?: TracingOptions): ModularApi {
  const api = new ModularApi({
    basePath: '/api',
    title: 'modular_api-test',
    ...(tracing === undefined ? {} : { tracing }),
  });
  api.module('cuenta', (m) => {
    m.usecase('ping', PingUseCase.fromJson, {
      inputClass: PingInput,
      outputClass: PingOutput,
    });
  });
  return api;
}

const spanNames = () => exporter.getFinishedSpans().map((span) => span.name);

describe('with TracingOptions', () => {
  it('a request through the real pipeline produces a server span', async () => {
    server = await apiWith(new TracingOptions({ tracerProvider: provider })).serve({ port: 0 });

    await request(server).post('/api/cuenta/ping').send({});

    expect(spanNames()).toContain('POST /api/cuenta/ping');
  });

  it('the span carries the route and a 200 status', async () => {
    server = await apiWith(new TracingOptions({ tracerProvider: provider })).serve({ port: 0 });

    await request(server).post('/api/cuenta/ping').send({});

    const span = exporter.getFinishedSpans().find((s) => s.name === 'POST /api/cuenta/ping');
    expect(span?.attributes['url.path']).toBe('/api/cuenta/ping');
    expect(span?.attributes['http.response.status_code']).toBe(200);
  });

  it('operational routes produce no span', async () => {
    // Health, docs, openapi and metrics are noise in a trace store. The host derives the exclusion
    // list from the operational paths rather than hardcoding it, so this also guards that list
    // against drift.
    server = await apiWith(new TracingOptions({ tracerProvider: provider })).serve({ port: 0 });

    await request(server).get('/api/health');

    expect(exporter.getFinishedSpans()).toHaveLength(0);
  });
});

describe('without TracingOptions (gate G3)', () => {
  it('no span is produced at all', async () => {
    // The structural half of G3: off means nothing installed, not "installed and idle". Even a no-op
    // tracer would have produced span objects here.
    server = await apiWith().serve({ port: 0 });

    const response = await request(server).post('/api/cuenta/ping').send({});

    expect(response.status).toBe(200);
    expect(exporter.getFinishedSpans()).toHaveLength(0);
  });

  it('the API still serves normally', async () => {
    // Invariant 3: a REST-only API is valid with or without optional plugins.
    server = await apiWith().serve({ port: 0 });

    const response = await request(server).post('/api/cuenta/ping').send({});

    expect(response.status).toBe(200);
    expect(response.body).toEqual({ echo: 'ping' });
    // The home-grown correlation header is untouched by tracing being absent.
    expect(response.headers['x-request-id']).toBeDefined();
  });
});
