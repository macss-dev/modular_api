import { context as otelContext, SpanKind, SpanStatusCode, trace, type Tracer } from '@opentelemetry/api';
import { InMemorySpanExporter, SimpleSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { NodeTracerProvider } from '@opentelemetry/sdk-trace-node';
import { beforeAll, beforeEach, describe, expect, it } from 'vitest';

import {
  DbClient,
  DbCommand,
  DbCommandKind,
  DbConnectionSettings,
  DbExecutionMetadata,
  DbExecutionSummary,
  DbFailure,
  DbFailureKind,
  DbProviderDescription,
  DbResult,
  DbRowSet,
  DbScalar,
  DbSessionLease,
  DbTransactionContext,
  type DbCommandExecutor,
  type DbSessionProvider,
  type DbTransactionRunner,
} from '../src/dbClient';
import { traceDbClient, type DbTracingOptions } from '../src/dbTracing';

/**
 * TypeScript mirror of `test/tracing_test.dart`.
 *
 * **Instrumentation is a decorator, not a change to `DbClient`.** ADR-0004 makes this package
 * contracts-only: `DbClient`, `DbRepository` and `DbTransactionContext` all delegate to an
 * application-supplied `DbCommandExecutor`. Wrapping that one collaborator instruments all three
 * call paths at once, including commands issued inside a transaction body, and leaves every
 * existing line of the package untouched.
 *
 * **The SQL text is off by default** (D9). The attribute is `db.query.text` — `db.statement` is
 * deprecated, a correction this stage made after checking the semantic conventions package itself
 * rather than trusting what the runbook had written down.
 */
const exporter = new InMemorySpanExporter();
let tracer: Tracer;

beforeAll(() => {
  const provider = new NodeTracerProvider({ spanProcessors: [new SimpleSpanProcessor(exporter)] });
  // `register()` installs the context manager. Without it `context.with` does not propagate and
  // every child span would silently become a root — the failure mode Stage 6 ran into.
  provider.register();
  tracer = provider.getTracer('test-host');
});

beforeEach(() => exporter.reset());

const spanNamed = (name: string) => exporter.getFinishedSpans().find((span) => span.name === name);
const spanNames = () => exporter.getFinishedSpans().map((span) => span.name);

const settings = DbConnectionSettings.fromEnvironment({
  MODULAR_API_POSTGRES_HOST: 'db.internal',
  MODULAR_API_POSTGRES_DATABASE: 'socia',
});

const selectUsers = new DbCommand({
  kind: DbCommandKind.query,
  text: 'SELECT id, dni FROM cuenta WHERE dni = @dni',
  parameters: ['12345678'],
  label: 'SELECT cuenta',
});

function clientFor({
  failure,
  acquireFailure,
  options = {},
}: {
  failure?: DbFailure;
  acquireFailure?: DbFailure;
  options?: DbTracingOptions;
} = {}): DbClient<string> {
  return traceDbClient(
    new DbClient<string>({
      settings,
      sessionProvider: new FakeSessionProvider(acquireFailure),
      commandExecutor: new FakeCommandExecutor(failure),
      transactionRunner: new FakeTransactionRunner<string>(),
    }),
    options,
  );
}

/**
 * Database spans are children of whatever the request made active, exactly as the client span in
 * `@macss/modular-api-rest-client` is. There is no separate wiring for it.
 */
async function withinServerSpan(body: () => Promise<unknown>): Promise<void> {
  const serverSpan = tracer.startSpan('POST /api/cuenta', { kind: SpanKind.SERVER });
  await otelContext.with(trace.setSpan(otelContext.active(), serverSpan), body);
  serverSpan.end();
}

describe('command spans', () => {
  it('a span wraps command execution, named by the command label', async () => {
    // The semantic conventions ask for a low-cardinality name and offer `db.query.summary` for it.
    // `DbCommand.label` is exactly that — application-supplied and stable — so it is preferred over
    // anything parsed out of the SQL.
    await withinServerSpan(() => clientFor().query(selectUsers));

    expect(spanNames()).toContain('SELECT cuenta');
  });

  it('an unlabelled command falls back to operation and namespace', async () => {
    // Never the SQL text: that is unbounded cardinality and possibly personal data.
    await withinServerSpan(() =>
      clientFor().query(new DbCommand({ kind: DbCommandKind.query, text: 'SELECT 1' })),
    );

    expect(spanNames()).toContain('SELECT socia');
  });

  it('the span is kind=client and a child of the active server span', async () => {
    // kind=client, not internal: a database call leaves the process.
    await withinServerSpan(() => clientFor().query(selectUsers));

    const server = spanNamed('POST /api/cuenta');
    const command = spanNamed('SELECT cuenta');

    expect(command?.kind).toBe(SpanKind.CLIENT);
    expect(command?.spanContext().traceId).toBe(server?.spanContext().traceId);
  });

  it('records the stable database attributes', async () => {
    await withinServerSpan(() => clientFor().query(selectUsers));

    const attributes = spanNamed('SELECT cuenta')?.attributes;

    expect(attributes?.['db.system.name']).toBe('postgresql');
    expect(attributes?.['db.namespace']).toBe('socia');
    expect(attributes?.['db.operation.name']).toBe('SELECT');
    expect(attributes?.['db.query.summary']).toBe('SELECT cuenta');
    expect(attributes?.['server.address']).toBe('db.internal');
    expect(attributes?.['server.port']).toBe(5432);
  });

  it('emits none of the deprecated database attributes', async () => {
    // Emitting them would fail silently against a current backend, which is worse than failing
    // loudly: it looks like the instrumentation not working.
    await withinServerSpan(() => clientFor().query(selectUsers));

    const attributes = spanNamed('SELECT cuenta')?.attributes;

    expect(attributes?.['db.system']).toBeUndefined();
    expect(attributes?.['db.name']).toBeUndefined();
    expect(attributes?.['db.operation']).toBeUndefined();
    expect(attributes?.['db.statement']).toBeUndefined();
  });

  it('db.system.name is the registered value, not our engine id', async () => {
    // Our `engineId` is `postgres`; the conventions register `postgresql`. A backend that keys its
    // Postgres dashboards off this attribute would not match on `postgres`.
    await withinServerSpan(() => clientFor().query(selectUsers));

    expect(spanNamed('SELECT cuenta')?.attributes['db.system.name']).toBe('postgresql');
  });

  it('the row count is recorded', async () => {
    await withinServerSpan(() => clientFor().query(selectUsers));

    expect(spanNamed('SELECT cuenta')?.attributes['db.response.returned_rows']).toBe(1);
  });

  it('execute and scalar are instrumented too, with their own operations', async () => {
    await withinServerSpan(async () => {
      const client = clientFor();
      await client.execute(
        new DbCommand({
          kind: DbCommandKind.execute,
          text: 'UPDATE cuenta SET saldo = 0',
          label: 'UPDATE cuenta',
        }),
      );
      await client.scalar(
        new DbCommand({
          kind: DbCommandKind.scalar,
          text: 'SELECT count(*) FROM cuenta',
          label: 'COUNT cuenta',
        }),
      );
    });

    expect(spanNamed('UPDATE cuenta')?.attributes['db.operation.name']).toBe('UPDATE');
    expect(spanNamed('COUNT cuenta')?.attributes['db.operation.name']).toBe('SELECT');
  });

  it('an unrecognised leading token yields no operation name', async () => {
    // The operation name comes from an allowlist of SQL verbs. Anything else — a leading comment, a
    // driver-specific directive — is dropped rather than emitted, which keeps the attribute
    // low-cardinality and cannot leak a fragment of the query.
    await withinServerSpan(() =>
      clientFor().query(
        new DbCommand({
          kind: DbCommandKind.query,
          text: '/* tenant 4471 */ SELECT 1',
          label: 'odd',
        }),
      ),
    );

    expect(spanNamed('odd')?.attributes['db.operation.name']).toBeUndefined();
  });
});

describe('the SQL text (D9)', () => {
  it('db.query.text is absent by default', async () => {
    await withinServerSpan(() => clientFor().query(selectUsers));

    expect(spanNamed('SELECT cuenta')?.attributes['db.query.text']).toBeUndefined();
  });

  it('db.query.text is present when explicitly opted in', async () => {
    await withinServerSpan(() =>
      clientFor({ options: { includeQueryText: true } }).query(selectUsers),
    );

    expect(spanNamed('SELECT cuenta')?.attributes['db.query.text']).toBe(
      'SELECT id, dni FROM cuenta WHERE dni = @dni',
    );
  });

  it('parameter values are never recorded, even when the text is', async () => {
    // The text is a template; the parameters are the data. Opting into one must not opt into the
    // other, or D9's protection would be pointless for a parameterised query.
    await withinServerSpan(() =>
      clientFor({ options: { includeQueryText: true } }).query(selectUsers),
    );

    const attributes = spanNamed('SELECT cuenta')?.attributes ?? {};

    for (const value of Object.values(attributes)) {
      expect(String(value)).not.toContain('12345678');
    }
  });
});

describe('failures', () => {
  const timeout = new DbFailure({
    kind: DbFailureKind.timeout,
    code: '57014',
    message: 'canceling statement due to statement timeout',
    retryable: true,
    transient: true,
  });

  it('a failed command sets error status and records the failure kind', async () => {
    // Failures arrive as a `DbResult`, not as a thrown exception, so the span has to inspect the
    // result. A decorator that only wrapped a try/catch would report every timeout as OK.
    await withinServerSpan(() => clientFor({ failure: timeout }).query(selectUsers));

    const span = spanNamed('SELECT cuenta');

    expect(span?.status.code).toBe(SpanStatusCode.ERROR);
    expect(span?.attributes['db.response.status_code']).toBe('57014');
    expect(span?.attributes['modular_api.db.failure_kind']).toBe('timeout');
  });

  it('the failure message is not copied into the span', async () => {
    // A driver message can quote the offending row. The code and kind are enough to diagnose.
    await withinServerSpan(() =>
      clientFor({
        failure: new DbFailure({
          kind: DbFailureKind.constraint,
          code: '23505',
          message: 'duplicate key value violates unique constraint: dni=12345678',
          retryable: false,
          transient: false,
        }),
      }).query(selectUsers),
    );

    const attributes = spanNamed('SELECT cuenta')?.attributes ?? {};

    for (const value of Object.values(attributes)) {
      expect(String(value)).not.toContain('12345678');
    }
  });

  it('the span is still ended when the command fails', async () => {
    await withinServerSpan(() => clientFor({ failure: timeout }).query(selectUsers));

    expect(spanNamed('SELECT cuenta')?.endTime).toBeDefined();
  });
});

describe('transactions', () => {
  it('a transaction span wraps the body', async () => {
    await withinServerSpan(() =>
      clientFor().transaction(async (context) => {
        await context.query(selectUsers);
        return DbResult.success(1);
      }),
    );

    expect(spanNames()).toContain('TRANSACTION socia');
  });

  it('commands inside the body nest under the transaction span', async () => {
    // This is what the decorator buys us: `DbTransactionContext` is built inside
    // `DbClient.transaction` from the same executor, so wrapping the executor once covers commands
    // issued through the transaction context as well.
    await withinServerSpan(() =>
      clientFor().transaction(async (context) => {
        await context.query(selectUsers);
        return DbResult.success(1);
      }),
    );

    const transaction = spanNamed('TRANSACTION socia');
    const command = spanNamed('SELECT cuenta');

    expect(command?.parentSpanContext?.spanId).toBe(transaction?.spanContext().spanId);
  });

  it('a failed transaction sets error status on the transaction span', async () => {
    await withinServerSpan(() =>
      clientFor().transaction(async () =>
        DbResult.failure(
          new DbFailure({
            kind: DbFailureKind.serialization,
            code: '40001',
            message: 'could not serialize access',
            retryable: true,
            transient: true,
          }),
        ),
      ),
    );

    const transaction = spanNamed('TRANSACTION socia');

    expect(transaction?.status.code).toBe(SpanStatusCode.ERROR);
    expect(transaction?.attributes['modular_api.db.failure_kind']).toBe('serialization');
  });
});

describe('session acquisition (D28)', () => {
  it('acquiring a session produces its own span', async () => {
    // The number that separates "the query was slow" from "we queued for a connection". Without it,
    // pool wait time lands in no span at all — an unattributed gap that reads as nothing having
    // happened.
    await withinServerSpan(() => clientFor().query(selectUsers));

    expect(spanNames()).toContain('CONNECT socia');
  });

  it('the acquisition span precedes the command span', async () => {
    await withinServerSpan(() => clientFor().query(selectUsers));

    const connect = spanNamed('CONNECT socia');
    const command = spanNamed('SELECT cuenta');

    expect(connect?.startTime[0]).toBeLessThanOrEqual(command?.startTime[0] ?? 0);
  });

  it('a failed acquisition is an error, and no command span follows', async () => {
    await withinServerSpan(() =>
      clientFor({
        acquireFailure: new DbFailure({
          kind: DbFailureKind.connectivity,
          code: 'pool_exhausted',
          message: 'no connection available',
          retryable: true,
          transient: true,
        }),
      }).query(selectUsers),
    );

    expect(spanNamed('CONNECT socia')?.status.code).toBe(SpanStatusCode.ERROR);
    expect(spanNames()).not.toContain('SELECT cuenta');
  });
});

describe('without tracing configured (G3)', () => {
  it('an unwrapped client produces no spans', async () => {
    // Instrumentation is opt-in by construction: not wrapping is how you turn it off, so the cost
    // of not using it is exactly zero rather than a branch per call.
    await withinServerSpan(() =>
      new DbClient<string>({
        settings,
        sessionProvider: new FakeSessionProvider(),
        commandExecutor: new FakeCommandExecutor(),
        transactionRunner: new FakeTransactionRunner<string>(),
      }).query(selectUsers),
    );

    expect(spanNames()).not.toContain('SELECT cuenta');
  });

  it('a wrapped client with no active span emits nothing', async () => {
    // No recording parent means the request was not sampled, or tracing is off entirely.
    await clientFor().query(selectUsers);

    expect(exporter.getFinishedSpans()).toHaveLength(0);
  });

  it('the call still succeeds with no active span', async () => {
    const result = await clientFor().query(selectUsers);

    expect(result.isSuccess).toBe(true);
  });

  it('wrapping preserves the provider description and settings', () => {
    // The wrapped client must be a drop-in replacement, including for the health contributor and
    // GraphQL support that read `describe()`.
    const client = clientFor();

    expect(client.describe().engineId).toBe('postgres');
    expect(client.settings.database).toBe('socia');
  });
});

class FakeSessionProvider implements DbSessionProvider<string> {
  public constructor(private readonly failure?: DbFailure) {}

  public async acquire(): Promise<DbResult<DbSessionLease<string>>> {
    if (this.failure !== undefined) return DbResult.failure(this.failure);
    return DbResult.success(
      new DbSessionLease<string>({
        session: 'session',
        ownedByPackage: true,
        releaser: async () => DbResult.success(undefined),
      }),
    );
  }

  public async close(): Promise<DbResult<void>> {
    return DbResult.success(undefined);
  }

  public describe(): DbProviderDescription {
    return new DbProviderDescription({
      engineId: settings.engineId,
      database: settings.database,
      redactedSummary: settings.redactedSummary,
      ownsResources: true,
    });
  }
}

const metadata = new DbExecutionMetadata({
  duration: 2,
  rowCount: 1,
  affectedCount: 1,
});

class FakeCommandExecutor implements DbCommandExecutor<string> {
  public constructor(private readonly failure?: DbFailure) {}

  public async query(): Promise<DbResult<DbRowSet>> {
    if (this.failure !== undefined) return DbResult.failure(this.failure);
    return DbResult.success(new DbRowSet({ rows: [{ id: 1 }], metadata }));
  }

  public async execute(): Promise<DbResult<DbExecutionSummary>> {
    if (this.failure !== undefined) return DbResult.failure(this.failure);
    return DbResult.success(new DbExecutionSummary({ affectedCount: 1, metadata }));
  }

  public async scalar<T>(): Promise<DbResult<DbScalar<T>>> {
    if (this.failure !== undefined) return DbResult.failure(this.failure);
    return DbResult.success(new DbScalar<T>({ value: 1 as T, metadata }));
  }
}

class FakeTransactionRunner<S> implements DbTransactionRunner<S> {
  public run<T>(
    context: DbTransactionContext<S>,
    body: (context: DbTransactionContext<S>) => Promise<DbResult<T>>,
  ): Promise<DbResult<T>> {
    return body(context);
  }
}
