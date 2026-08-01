/**
 * Emits the span shape one representative request produces, as JSON on stdout.
 *
 * **Gate G6's input.** Three mirrored test suites can drift in a way no single-language test
 * catches: a test asserts the attributes that *are* there and never the ones that are not, so an
 * extra attribute in one language passes everywhere. This dump is compared key-for-key against
 * `code/tests/fixtures/tracing/span_shape.json` by
 * `code/tests/integration_test/tracing_parity_test.ps1`, which makes the exact attribute set — not a
 * subset — the thing under test.
 *
 * Ids, timestamps and durations are deliberately excluded: they differ every run and are the SDK's
 * business. Parentage is expressed by the parent's *name*, which is stable and is what a waterfall
 * actually shows.
 *
 * Run: `npx tsx tool/dumpSpanShape.ts`
 * Counterparts: `code/dart/modular_api/tool/dump_span_shape.dart`,
 * `code/py/modular_api/tools/dump_span_shape.py`
 */

import { SpanKind, trace } from '@opentelemetry/api';
import { InMemorySpanExporter, SimpleSpanProcessor, type ReadableSpan } from '@opentelemetry/sdk-trace-base';
import { NodeTracerProvider } from '@opentelemetry/sdk-trace-node';
import type { Server } from 'node:http';

import { Field, Input, ModularApi, Output, type ModularLogger, type UseCase } from '../src/index';
import { TracingOptions } from '../src/core/tracing/tracingOptions';

class DetalleInput extends Input {
  @Field.string({ description: 'Document number', example: '1' })
  dni!: string;
}

class DetalleOutput extends Output {
  @Field.string({ description: 'Echo of the input', example: '1' })
  echo!: string;

  get statusCode(): number {
    return 200;
  }
}

/**
 * Stands in for a handler that calls something downstream.
 *
 * The nested span is created with the plain OTel API and no argument threaded in: reaching the
 * server span through ambient context alone is the mechanism `@macss/modular-api-rest-client` and
 * `@macss/modular-api-postgres` use, so comparing it across languages compares theirs too — without
 * core depending on them.
 */
class Detalle implements UseCase<DetalleInput, DetalleOutput> {
  readonly input: DetalleInput;
  logger?: ModularLogger;

  constructor(input: DetalleInput) {
    this.input = input;
  }

  static fromJson(json: Record<string, unknown>): Detalle {
    const input = new DetalleInput();
    input.dni = json['dni'] as string;
    return new Detalle(input);
  }

  validate(): string | null {
    return null;
  }

  async execute(): Promise<DetalleOutput> {
    trace.getTracer('span-shape').startSpan('upstream impulsa', { kind: SpanKind.CLIENT }).end();

    const output = new DetalleOutput();
    output.echo = this.input.dni;
    return output;
  }
}

async function main(): Promise<void> {
  const exporter = new InMemorySpanExporter();
  const provider = new NodeTracerProvider({ spanProcessors: [new SimpleSpanProcessor(exporter)] });
  // Without `register()` there is no context manager, `context.with` does not propagate, and the
  // nested span would silently come out as a root. The same trap Stage 6 hit.
  provider.register();

  const api = new ModularApi({
    basePath: '/api',
    title: 'span-shape',
    tracing: new TracingOptions({ tracerProvider: provider }),
  });
  api.module('cuenta', (m) => {
    m.usecase('detalle', Detalle.fromJson, {
      inputClass: DetalleInput,
      outputClass: DetalleOutput,
    });
  });

  const server: Server = await api.serve({ port: 0 });
  const address = server.address();
  const port = typeof address === 'object' && address !== null ? address.port : 0;

  await fetch(`http://127.0.0.1:${port}/api/cuenta/detalle`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      // Sent so `http.request.header.x-request-id` is part of the shape. Without it the attribute is
      // conditionally absent in all three, and the comparison would not cover the one attribute
      // whose presence depends on the request.
      'x-request-id': 'parity-fixture',
    },
    body: JSON.stringify({ dni: '12345678' }),
  });

  await new Promise<void>((resolve) => server.close(() => resolve()));
  await new Promise<void>((resolve) => setImmediate(resolve));

  const captured = exporter.getFinishedSpans();
  const spans = captured
    .map((span) => ({
      name: span.name,
      kind: SpanKind[span.kind].toLowerCase(),
      parent: parentName(span, captured),
      attributeKeys: Object.keys(span.attributes).sort(),
    }))
    .sort((a, b) => a.name.localeCompare(b.name));

  // Sentinel-prefixed, because the framework logs its own JSON lines to stdout and the harness must
  // not have to guess which line is the payload.
  process.stdout.write(`SPAN_SHAPE_JSON:${JSON.stringify({ spans })}\n`);
  process.exit(0);
}

/**
 * The name of `span`'s parent, or `null` when it is a root.
 *
 * By name rather than id, because ids are excluded from the fixture.
 */
function parentName(span: ReadableSpan, all: readonly ReadableSpan[]): string | null {
  const parentId = span.parentSpanContext?.spanId;
  if (parentId === undefined) return null;

  return all.find((candidate) => candidate.spanContext().spanId === parentId)?.name ?? '<unknown>';
}

void main();
