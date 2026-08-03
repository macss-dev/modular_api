import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';

import 'modular_api_postgres.dart';

/// How much a database span is allowed to say.
final class DbTracingOptions {
  const DbTracingOptions({
    this.includeQueryText = false,
    this.instrumentationName = 'modular_api_postgres',
  });

  /// Whether to record the SQL text as `db.query.text`.
  ///
  /// **Off by default** (runbook D9). SQL can carry personal or financial data in a literal,
  /// and a span is not a place that is reviewed for that. Parameter *values* are never recorded
  /// regardless of this setting: the text is a template, the parameters are the data.
  final bool includeQueryText;

  final String instrumentationName;
}

/// Wraps [client] so its commands, transactions and session acquisitions produce spans.
///
/// **Instrumentation is a decorator over the contract, not a change to [DbClient].** ADR-0004
/// makes this package contracts-only, and [DbClient], [DbRepository] and [DbTransactionContext]
/// all delegate to the same application-supplied [DbCommandExecutor]. Wrapping that one
/// collaborator instruments every call path at once — including commands issued inside a
/// transaction body, which [DbClient.transaction] routes through a freshly built
/// [DbTransactionContext] carrying the same executor.
///
/// It follows that **not wrapping is how you turn tracing off**, so the cost of not using it is
/// zero rather than a branch per call (gate G3). The wrapped client is a drop-in replacement:
/// same settings, same [DbProviderDescription], so [DbHealthContributor] and GraphQL support keep
/// working unchanged.
///
/// A repository built from the wrapped client is instrumented too — call
/// [DbClient.repositoryContext] on the result rather than on the original.
DbClient<S> traceDbClient<S>(
  DbClient<S> client, {
  DbTracingOptions options = const DbTracingOptions(),
}) {
  final tracer = OTelAPI.tracerProvider().getTracer(options.instrumentationName);
  final target = _DbTarget(client.settings);

  return DbClient<S>(
    settings: client.settings,
    sessionProvider: _TracedSessionProvider<S>(
      client.sessionProvider,
      tracer: tracer,
      target: target,
    ),
    commandExecutor: _TracedCommandExecutor<S>(
      client.commandExecutor,
      tracer: tracer,
      target: target,
      options: options,
    ),
    transactionRunner: _TracedTransactionRunner<S>(
      client.transactionRunner,
      tracer: tracer,
      target: target,
    ),
  );
}

/// The attributes that describe *where* the database is, computed once per client.
final class _DbTarget {
  _DbTarget(DbConnectionSettings settings)
      : namespace = settings.database,
        host = settings.host,
        port = settings.port;

  final String namespace;
  final String host;
  final int port;

  /// The value the semantic conventions register for Postgres.
  ///
  /// Deliberately not `settings.engineId`, which is `postgres`: a backend keying its Postgres
  /// dashboards off `db.system.name` would not match on that.
  static const String systemName = 'postgresql';
}

/// The SQL verbs an operation name may take.
///
/// An allowlist rather than "the first word", so an unusual leading token — a comment, a
/// driver directive — is dropped instead of emitted. That keeps the attribute low-cardinality
/// and makes it impossible for a fragment of a query to arrive as an operation name.
const Set<String> _sqlOperations = {
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
};

String? _operationName(DbCommand command) {
  final trimmed = command.text.trimLeft();
  if (trimmed.isEmpty) return null;

  var end = 0;
  while (end < trimmed.length && _isWordCharacter(trimmed.codeUnitAt(end))) {
    end++;
  }
  if (end == 0) return null;

  final candidate = trimmed.substring(0, end).toUpperCase();
  return _sqlOperations.contains(candidate) ? candidate : null;
}

bool _isWordCharacter(int codeUnit) =>
    (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
    (codeUnit >= 0x61 && codeUnit <= 0x7A) ||
    codeUnit == 0x5F;

/// Starts a span for one database operation, or returns `null` when tracing is off.
///
/// `null` rather than a non-recording span: with no recording parent there is nothing to attach
/// to, and a span nobody will read is cost with no benefit.
APISpan? _startDbSpan(
  APITracer tracer, {
  required String? operation,
  required String? summary,
  required _DbTarget target,
  String? queryText,
  int? batchSize,
}) {
  final parent = Context.current.span;
  if (parent == null || !parent.isRecording) return null;

  final attributes = <String, Object>{
    'db.system.name': _DbTarget.systemName,
    'db.namespace': target.namespace,
    'server.address': target.host,
    'server.port': target.port,
    'db.operation.name': ?operation,
    'db.query.summary': ?summary,
    'db.query.text': ?queryText,
    'db.operation.batch.size': ?batchSize,
  };

  return tracer.startSpan(
    // The conventions ask for `{operation} {target}`, and prefer `db.query.summary` when one
    // exists. `DbCommand.label` is exactly that — application-supplied and stable — so it wins
    // over anything derived from the SQL. Never the SQL text itself: unbounded cardinality, and
    // possibly personal data.
    summary ?? '${operation ?? 'QUERY'} ${target.namespace}',
    kind: SpanKind.client, // A database call leaves the process.
    attributes: attributes.toAttributes(),
  );
}

/// Records the outcome on [span] and ends it.
///
/// Failures arrive as a [DbResult], never as a thrown exception, so this inspects the result. A
/// decorator that only wrapped a try/catch would report every timeout as a success.
///
/// The failure *message* is deliberately not copied: a driver message can quote the offending
/// row. The code and the kind are what diagnose the problem.
void _endDbSpan(APISpan? span, DbResult<Object?> result, {int? returnedRows}) {
  if (span == null) return;

  if (result.isFailure) {
    final failure = result.failure;
    span.setStringAttribute<String>('db.response.status_code', failure.code);
    span.setStringAttribute<String>(
      'modular_api.db.failure_kind',
      failure.kind.name,
    );
    span.setStatus(SpanStatusCode.Error);
  } else if (returnedRows != null) {
    span.setIntAttribute('db.response.returned_rows', returnedRows);
  }

  span.end();
}

final class _TracedCommandExecutor<S> implements DbCommandExecutor<S> {
  _TracedCommandExecutor(
    this._inner, {
    required APITracer tracer,
    required _DbTarget target,
    required DbTracingOptions options,
  })  : _tracer = tracer,
        _target = target,
        _options = options;

  final DbCommandExecutor<S> _inner;
  final APITracer _tracer;
  final _DbTarget _target;
  final DbTracingOptions _options;

  APISpan? _start(DbCommand command) => _startDbSpan(
        _tracer,
        operation: _operationName(command),
        summary: command.label,
        target: _target,
        queryText: _options.includeQueryText ? command.text : null,
        batchSize: command.kind == DbCommandKind.batch ? command.parameters.length : null,
      );

  @override
  Future<DbResult<DbRowSet>> query(S session, DbCommand command) async {
    final span = _start(command);
    final result = await _inner.query(session, command);
    _endDbSpan(
      span,
      result,
      returnedRows: result.isSuccess
          ? (result.value.metadata.rowCount ?? result.value.rows.length)
          : null,
    );
    return result;
  }

  @override
  Future<DbResult<DbExecutionSummary>> execute(S session, DbCommand command) async {
    final span = _start(command);
    final result = await _inner.execute(session, command);
    _endDbSpan(span, result);
    return result;
  }

  @override
  Future<DbResult<DbScalar<T>>> scalar<T>(S session, DbCommand command) async {
    final span = _start(command);
    final result = await _inner.scalar<T>(session, command);
    _endDbSpan(span, result);
    return result;
  }
}

final class _TracedTransactionRunner<S> implements DbTransactionRunner<S> {
  _TracedTransactionRunner(
    this._inner, {
    required APITracer tracer,
    required _DbTarget target,
  })  : _tracer = tracer,
        _target = target;

  final DbTransactionRunner<S> _inner;
  final APITracer _tracer;
  final _DbTarget _target;

  @override
  Future<DbResult<T>> run<T>(
    DbTransactionContext<S> context,
    Future<DbResult<T>> Function(DbTransactionContext<S> context) body,
  ) async {
    final span = _startDbSpan(
      _tracer,
      operation: 'TRANSACTION',
      summary: null,
      target: _target,
    );
    if (span == null) return _inner.run<T>(context, body);

    // Made ambient so commands issued through the transaction context become its children
    // rather than siblings — the nesting is what makes a transaction readable in a waterfall.
    final result = await _tracer.withSpanAsync(
      span,
      () => _inner.run<T>(context, body),
    );
    _endDbSpan(span, result);
    return result;
  }
}

final class _TracedSessionProvider<S> implements DbSessionProvider<S> {
  _TracedSessionProvider(
    this._inner, {
    required APITracer tracer,
    required _DbTarget target,
  })  : _tracer = tracer,
        _target = target;

  final DbSessionProvider<S> _inner;
  final APITracer _tracer;
  final _DbTarget _target;

  /// Acquisition gets its own span (runbook D28).
  ///
  /// Without it, time spent waiting for a connection lands in no span at all — an unattributed
  /// gap that reads as nothing having happened rather than as queueing for the pool. Pool
  /// exhaustion is a live hypothesis for `socia`, so this is the number that confirms or kills it.
  @override
  Future<DbResult<DbSessionLease<S>>> acquire() async {
    final span = _startDbSpan(
      _tracer,
      operation: 'CONNECT',
      summary: null,
      target: _target,
    );
    final result = await _inner.acquire();
    _endDbSpan(span, result);
    return result;
  }

  @override
  Future<DbResult<void>> close() => _inner.close();

  @override
  DbProviderDescription describe() => _inner.describe();
}
