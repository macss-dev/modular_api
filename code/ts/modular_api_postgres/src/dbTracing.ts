import {
  context as otelContext,
  SpanKind,
  SpanStatusCode,
  trace,
  type Attributes,
  type Span,
  type Tracer,
} from '@opentelemetry/api';

import {
  DbClient,
  DbCommandKind,
  type DbCommand,
  type DbCommandExecutor,
  type DbConnectionSettings,
  type DbExecutionSummary,
  type DbProviderDescription,
  type DbResult,
  type DbRowSet,
  type DbScalar,
  type DbSessionLease,
  type DbSessionProvider,
  type DbTransactionContext,
  type DbTransactionRunner,
} from './dbClient';

/** How much a database span is allowed to say. */
export interface DbTracingOptions {
  /**
   * Whether to record the SQL text as `db.query.text`.
   *
   * **Off by default** (runbook D9). SQL can carry personal or financial data in a literal, and a
   * span is not a place that is reviewed for that. Parameter *values* are never recorded regardless
   * of this setting: the text is a template, the parameters are the data.
   */
  readonly includeQueryText?: boolean;
  readonly instrumentationName?: string;
}

/**
 * Wraps `client` so its commands, transactions and session acquisitions produce spans.
 *
 * **Instrumentation is a decorator over the contract, not a change to `DbClient`.** ADR-0004 makes
 * this package contracts-only, and `DbClient`, `DbRepository` and `DbTransactionContext` all
 * delegate to the same application-supplied `DbCommandExecutor`. Wrapping that one collaborator
 * instruments every call path at once — including commands issued inside a transaction body, which
 * `DbClient.transaction` routes through a freshly built `DbTransactionContext` carrying the same
 * executor.
 *
 * It follows that **not wrapping is how you turn tracing off**, so the cost of not using it is zero
 * rather than a branch per call (gate G3). The wrapped client is a drop-in replacement: same
 * settings, same `DbProviderDescription`, so `DbHealthContributor` and GraphQL support keep working
 * unchanged.
 *
 * A repository built from the wrapped client is instrumented too — call `repositoryContext()` on the
 * result rather than on the original.
 */
export function traceDbClient<S>(
  client: DbClient<S>,
  options: DbTracingOptions = {},
): DbClient<S> {
  const tracer = trace.getTracer(options.instrumentationName ?? 'modular_api_postgres');
  const target = new DbTarget(client.settings);

  return new DbClient<S>({
    settings: client.settings,
    sessionProvider: new TracedSessionProvider<S>(client.sessionProvider, tracer, target),
    commandExecutor: new TracedCommandExecutor<S>(
      client.commandExecutor,
      tracer,
      target,
      options,
    ),
    transactionRunner: new TracedTransactionRunner<S>(client.transactionRunner, tracer, target),
  });
}

/** The attributes that describe *where* the database is, computed once per client. */
class DbTarget {
  /**
   * The value the semantic conventions register for Postgres.
   *
   * Deliberately not `settings.engineId`, which is `postgres`: a backend keying its Postgres
   * dashboards off `db.system.name` would not match on that.
   */
  public static readonly systemName = 'postgresql';

  public readonly namespace: string;
  public readonly host: string;
  public readonly port: number;

  public constructor(settings: DbConnectionSettings) {
    this.namespace = settings.database;
    this.host = settings.host;
    this.port = settings.port;
  }
}

/**
 * The SQL verbs an operation name may take.
 *
 * An allowlist rather than "the first word", so an unusual leading token — a comment, a driver
 * directive — is dropped instead of emitted. That keeps the attribute low-cardinality and makes it
 * impossible for a fragment of a query to arrive as an operation name.
 */
const SQL_OPERATIONS = new Set([
  'SELECT',
  'INSERT',
  'UPDATE',
  'DELETE',
  'MERGE',
  'UPSERT',
  'CALL',
  'WITH',
  'CREATE',
  'ALTER',
  'DROP',
  'TRUNCATE',
  'GRANT',
  'REVOKE',
  'EXPLAIN',
  'ANALYZE',
  'VACUUM',
  'COPY',
  'BEGIN',
  'COMMIT',
  'ROLLBACK',
  'SET',
  'SHOW',
  'LISTEN',
  'NOTIFY',
  'REFRESH',
]);

function operationName(command: DbCommand): string | undefined {
  const match = /^\s*([A-Za-z_]+)/.exec(command.text);
  if (match === null) return undefined;

  const candidate = match[1].toUpperCase();
  return SQL_OPERATIONS.has(candidate) ? candidate : undefined;
}

interface DbSpanInit {
  readonly operation?: string;
  readonly summary?: string;
  readonly target: DbTarget;
  readonly queryText?: string;
  readonly batchSize?: number;
}

/**
 * Starts a span for one database operation, or returns `undefined` when tracing is off.
 *
 * `undefined` rather than a non-recording span: with no recording parent there is nothing to attach
 * to, and a span nobody will read is cost with no benefit.
 */
function startDbSpan(tracer: Tracer, init: DbSpanInit): Span | undefined {
  const parent = trace.getSpan(otelContext.active());
  if (parent === undefined || !parent.isRecording()) return undefined;

  const attributes: Attributes = {
    'db.system.name': DbTarget.systemName,
    'db.namespace': init.target.namespace,
    'server.address': init.target.host,
    'server.port': init.target.port,
  };
  if (init.operation !== undefined) attributes['db.operation.name'] = init.operation;
  if (init.summary !== undefined) attributes['db.query.summary'] = init.summary;
  if (init.queryText !== undefined) attributes['db.query.text'] = init.queryText;
  if (init.batchSize !== undefined) attributes['db.operation.batch.size'] = init.batchSize;

  return tracer.startSpan(
    // The conventions ask for `{operation} {target}`, and prefer `db.query.summary` when one
    // exists. `DbCommand.label` is exactly that — application-supplied and stable — so it wins over
    // anything derived from the SQL. Never the SQL text itself: unbounded cardinality, and possibly
    // personal data.
    init.summary ?? `${init.operation ?? 'QUERY'} ${init.target.namespace}`,
    {
      kind: SpanKind.CLIENT, // A database call leaves the process.
      attributes,
    },
  );
}

/**
 * Records the outcome on `span` and ends it.
 *
 * Failures arrive as a `DbResult`, never as a thrown exception, so this inspects the result. A
 * decorator that only wrapped a try/catch would report every timeout as a success.
 *
 * The failure *message* is deliberately not copied: a driver message can quote the offending row.
 * The code and the kind are what diagnose the problem.
 */
function endDbSpan(
  span: Span | undefined,
  result: DbResult<unknown>,
  returnedRows?: number,
): void {
  if (span === undefined) return;

  if (result.isFailure) {
    span.setAttribute('db.response.status_code', result.failure.code);
    span.setAttribute('modular_api.db.failure_kind', result.failure.kind);
    span.setStatus({ code: SpanStatusCode.ERROR });
  } else if (returnedRows !== undefined) {
    span.setAttribute('db.response.returned_rows', returnedRows);
  }

  span.end();
}

class TracedCommandExecutor<S> implements DbCommandExecutor<S> {
  public constructor(
    private readonly inner: DbCommandExecutor<S>,
    private readonly tracer: Tracer,
    private readonly target: DbTarget,
    private readonly options: DbTracingOptions,
  ) {}

  public async query(session: S, command: DbCommand): Promise<DbResult<DbRowSet>> {
    const span = this.start(command);
    const result = await this.inner.query(session, command);
    endDbSpan(
      span,
      result,
      result.isSuccess ? (result.value.metadata.rowCount ?? result.value.rows.length) : undefined,
    );
    return result;
  }

  public async execute(session: S, command: DbCommand): Promise<DbResult<DbExecutionSummary>> {
    const span = this.start(command);
    const result = await this.inner.execute(session, command);
    endDbSpan(span, result);
    return result;
  }

  public async scalar<T>(session: S, command: DbCommand): Promise<DbResult<DbScalar<T>>> {
    const span = this.start(command);
    const result = await this.inner.scalar<T>(session, command);
    endDbSpan(span, result);
    return result;
  }

  private start(command: DbCommand): Span | undefined {
    return startDbSpan(this.tracer, {
      operation: operationName(command),
      summary: command.label,
      target: this.target,
      queryText: this.options.includeQueryText === true ? command.text : undefined,
      batchSize: command.kind === DbCommandKind.batch ? command.parameters.length : undefined,
    });
  }
}

class TracedTransactionRunner<S> implements DbTransactionRunner<S> {
  public constructor(
    private readonly inner: DbTransactionRunner<S>,
    private readonly tracer: Tracer,
    private readonly target: DbTarget,
  ) {}

  public async run<T>(
    context: DbTransactionContext<S>,
    body: (context: DbTransactionContext<S>) => Promise<DbResult<T>>,
  ): Promise<DbResult<T>> {
    const span = startDbSpan(this.tracer, { operation: 'TRANSACTION', target: this.target });
    if (span === undefined) return this.inner.run(context, body);

    // Made ambient so commands issued through the transaction context become its children rather
    // than siblings — the nesting is what makes a transaction readable in a waterfall.
    const result = await otelContext.with(
      trace.setSpan(otelContext.active(), span),
      () => this.inner.run(context, body),
    );
    endDbSpan(span, result);
    return result;
  }
}

class TracedSessionProvider<S> implements DbSessionProvider<S> {
  public constructor(
    private readonly inner: DbSessionProvider<S>,
    private readonly tracer: Tracer,
    private readonly target: DbTarget,
  ) {}

  /**
   * Acquisition gets its own span (runbook D28).
   *
   * Without it, time spent waiting for a connection lands in no span at all — an unattributed gap
   * that reads as nothing having happened rather than as queueing for the pool. Pool exhaustion is a
   * live hypothesis for `socia`, so this is the number that confirms or kills it.
   */
  public async acquire(): Promise<DbResult<DbSessionLease<S>>> {
    const span = startDbSpan(this.tracer, { operation: 'CONNECT', target: this.target });
    const result = await this.inner.acquire();
    endDbSpan(span, result);
    return result;
  }

  public close(): Promise<DbResult<void>> {
    return this.inner.close();
  }

  public describe(): DbProviderDescription {
    return this.inner.describe();
  }
}
