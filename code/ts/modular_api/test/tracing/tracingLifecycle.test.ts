import { InMemorySpanExporter, SimpleSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { NodeTracerProvider } from '@opentelemetry/sdk-trace-node';
import type { Server } from 'node:http';
import { beforeAll, describe, expect, it } from 'vitest';

import { ModularApi } from '../../src/core/modular_api';
import { TracingOptions } from '../../src/core/tracing/tracingOptions';

/**
 * TypeScript mirror of `test/tracing/tracing_lifecycle_test.dart`.
 *
 * **There is deliberately no tracing plugin** (ADR-0005 A7). Every responsibility decision 4
 * assigned to one was reassigned: A2 moved the sampler, processor and exporter to the
 * application; the span became host-owned so no middleware is registered; the shutdown
 * became a callback; and D14 removed the dropped-span counter. The host reads
 * `TracingOptions` directly.
 *
 * D8's revision is starker here than in Dart: `TracerProvider` in `@opentelemetry/api`
 * exposes only `getTracer`. The framework *could not* flush the provider even if it wanted
 * to, which is half of why the responsibility moved to the application.
 */
const exporter = new InMemorySpanExporter();
let provider: NodeTracerProvider;

beforeAll(() => {
  provider = new NodeTracerProvider({ spanProcessors: [new SimpleSpanProcessor(exporter)] });
  provider.register();
});

const options = (onShutdown?: () => Promise<void>): TracingOptions =>
  new TracingOptions({
    tracerProvider: provider,
    ...(onShutdown === undefined ? {} : { onShutdown }),
  });

async function serveAndClose(tracing?: TracingOptions): Promise<void> {
  const api = new ModularApi({ basePath: '/api', title: 'modular_api-test', ...(tracing ? { tracing } : {}) });
  const server: Server = await api.serve({ port: 0 });
  await new Promise<void>((resolve) => server.close(() => resolve()));
  // `close` fires the handler asynchronously; give the microtask queue a turn.
  await new Promise<void>((resolve) => setImmediate(resolve));
}

describe('shutdown timing (D8 as revised)', () => {
  it('onShutdown runs when the server closes', async () => {
    // On Cloud Run this is the only window before the container dies. The framework
    // supplies the moment; the application supplies the action.
    let called = 0;

    await serveAndClose(options(async () => void called++));

    expect(called).toBe(1);
  });

  it('a missing onShutdown is not an error', async () => {
    await expect(serveAndClose(options())).resolves.toBeUndefined();
  });

  it('an onShutdown that rejects does not prevent the server closing', async () => {
    // A failing flush must not turn a clean shutdown into a hang or a crash.
    await expect(
      serveAndClose(
        options(async () => {
          throw new Error('flush failed');
        }),
      ),
    ).resolves.toBeUndefined();
  });

  it('the framework does not shut down the provider itself', async () => {
    // It could not: TracerProvider in @opentelemetry/api exposes only getTracer. Asserting
    // it anyway, because the test states the intent rather than the accident.
    await serveAndClose(options());

    const span = provider.getTracer('after-shutdown').startSpan('still-working');
    span.end();

    expect(span.spanContext().traceId).toBeDefined();
  });
});

describe('configuration', () => {
  it('the instrumentation name defaults to modular_api', () => {
    expect(options().instrumentationName).toBe('modular_api');
  });

  it('the instrumentation name can be overridden', () => {
    expect(
      new TracingOptions({ tracerProvider: provider, instrumentationName: 'socia-api' })
        .instrumentationName,
    ).toBe('socia-api');
  });
});
