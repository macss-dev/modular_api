import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as sdk;
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:modular_api_postgres/modular_api_postgres.dart';
import 'package:test/test.dart';

/// Tests for database spans.
///
/// **Instrumentation is a decorator, not a change to `DbClient`.** ADR-0004 makes this package
/// contracts-only: `DbClient`, `DbRepository` and `DbTransactionContext` all delegate to an
/// application-supplied `DbCommandExecutor`. Wrapping that one collaborator instruments all three
/// call paths at once, including commands issued inside a transaction body, and leaves every
/// existing line of the package untouched. Instrumenting the three classes directly would have
/// meant editing a base class applications extend.
///
/// That is also why enabling tracing here is `traceDbClient(client)` rather than an options flag
/// on `DbClient`: the contract is the seam, so the seam is where instrumentation goes.
///
/// **The SQL text is off by default** (D9). `socia` is preparing an external security audit and
/// SQL can carry personal data. The attribute is `db.query.text` — `db.statement` is deprecated,
/// which is a correction this stage made after checking the semantic conventions package itself.
void main() {
  late TestHarness harness;
  late InMemorySpanExporter spans;
  late APITracer tracer;

  setUpAll(() async {
    harness = await maybeInitializeOtelForTest(serviceName: 'postgres-test');
    spans = harness.spans;
    tracer = sdk.OTel.tracerProvider().getTracer('test-host');
  });

  setUp(() => harness.clear());

  final settings = DbConnectionSettings.fromEnvironment(
    environment: const {
      'MODULAR_API_POSTGRES_HOST': 'db.internal',
      'MODULAR_API_POSTGRES_DATABASE': 'socia',
    },
  );

  DbClient<String> clientFor({
    DbFailure? failure,
    DbTracingOptions options = const DbTracingOptions(),
  }) {
    return traceDbClient(
      DbClient<String>(
        settings: settings,
        sessionProvider: _FakeSessionProvider(settings),
        commandExecutor: _FakeCommandExecutor(failure: failure),
        transactionRunner: _FakeTransactionRunner<String>(),
      ),
      options: options,
    );
  }

  const selectUsers = DbCommand(
    kind: DbCommandKind.query,
    text: 'SELECT id, dni FROM cuenta WHERE dni = @dni',
    parameters: ['12345678'],
    label: 'SELECT cuenta',
  );

  /// Database spans are children of whatever the request made active, exactly as the client span
  /// in `modular_api_rest_client` is. There is no separate wiring for it.
  Future<void> withinServerSpan(Future<void> Function() body) async {
    final serverSpan = tracer.startSpan('POST /api/cuenta', kind: SpanKind.server);
    await tracer.withSpanAsync(serverSpan, body);
    serverSpan.end();
  }

  group('command spans', () {
    test('a span wraps command execution, named by the command label', () async {
      // The semantic conventions ask for a low-cardinality name and offer `db.query.summary`
      // for it. `DbCommand.label` is exactly that — application-supplied and stable — so it is
      // preferred over anything parsed out of the SQL.
      await withinServerSpan(() async => clientFor().query(selectUsers));

      expect(spans.spanNames, contains('SELECT cuenta'));
    });

    test('an unlabelled command falls back to operation and namespace', () async {
      // Never the SQL text: that is unbounded cardinality and possibly personal data.
      await withinServerSpan(
        () async => clientFor().query(
          const DbCommand(kind: DbCommandKind.query, text: 'SELECT 1'),
        ),
      );

      expect(spans.spanNames, contains('SELECT socia'));
    });

    test('the span is kind=client and a child of the active server span', () async {
      // kind=client, not internal: a database call leaves the process.
      await withinServerSpan(() async => clientFor().query(selectUsers));

      final server = spans.findSpanByName('POST /api/cuenta')!;
      final command = spans.findSpanByName('SELECT cuenta')!;

      expect(command.kind, equals(SpanKind.client));
      expect(
        command.spanContext.traceId.hexString,
        equals(server.spanContext.traceId.hexString),
      );
    });

    test('records the stable database attributes', () async {
      // `db.system.name`, `db.namespace` and `db.operation.name`. The deprecated `db.system`,
      // `db.name` and `db.operation` are asserted absent below, because emitting them would fail
      // silently against a current backend.
      await withinServerSpan(() async => clientFor().query(selectUsers));

      final attributes = spans.findSpanByName('SELECT cuenta')!.attributes;

      expect(attributes.getString('db.system.name'), equals('postgresql'));
      expect(attributes.getString('db.namespace'), equals('socia'));
      expect(attributes.getString('db.operation.name'), equals('SELECT'));
      expect(attributes.getString('db.query.summary'), equals('SELECT cuenta'));
      expect(attributes.getString('server.address'), equals('db.internal'));
      expect(attributes.getInt('server.port'), equals(5432));
    });

    test('emits none of the deprecated database attributes', () async {
      await withinServerSpan(() async => clientFor().query(selectUsers));

      final attributes = spans.findSpanByName('SELECT cuenta')!.attributes;

      expect(attributes.getString('db.system'), isNull);
      expect(attributes.getString('db.name'), isNull);
      expect(attributes.getString('db.operation'), isNull);
      expect(attributes.getString('db.statement'), isNull);
    });

    test('db.system.name is the registered value, not our engine id', () async {
      // Our `engineId` is `postgres`; the conventions register `postgresql`. A backend that keys
      // its Postgres dashboards off this attribute would not match on `postgres`.
      await withinServerSpan(() async => clientFor().query(selectUsers));

      expect(
        spans.findSpanByName('SELECT cuenta')!.attributes.getString('db.system.name'),
        equals('postgresql'),
      );
    });

    test('the row count is recorded', () async {
      await withinServerSpan(() async => clientFor().query(selectUsers));

      expect(
        spans
            .findSpanByName('SELECT cuenta')!
            .attributes
            .getInt('db.response.returned_rows'),
        equals(1),
      );
    });

    test('execute and scalar are instrumented too, with their own operations', () async {
      await withinServerSpan(() async {
        final client = clientFor();
        await client.execute(
          const DbCommand(
            kind: DbCommandKind.execute,
            text: 'UPDATE cuenta SET saldo = 0',
            label: 'UPDATE cuenta',
          ),
        );
        await client.scalar<Object?>(
          const DbCommand(
            kind: DbCommandKind.scalar,
            text: 'SELECT count(*) FROM cuenta',
            label: 'COUNT cuenta',
          ),
        );
      });

      expect(
        spans.findSpanByName('UPDATE cuenta')!.attributes.getString('db.operation.name'),
        equals('UPDATE'),
      );
      expect(
        spans.findSpanByName('COUNT cuenta')!.attributes.getString('db.operation.name'),
        equals('SELECT'),
      );
    });

    test('an unrecognised leading token yields no operation name', () async {
      // The operation name is taken from an allowlist of SQL verbs. Anything else — a leading
      // comment, a driver-specific directive — is dropped rather than emitted, which keeps the
      // attribute low-cardinality and cannot leak a fragment of the query.
      await withinServerSpan(
        () async => clientFor().query(
          const DbCommand(
            kind: DbCommandKind.query,
            text: '/* tenant 4471 */ SELECT 1',
            label: 'odd',
          ),
        ),
      );

      expect(
        spans.findSpanByName('odd')!.attributes.getString('db.operation.name'),
        isNull,
      );
    });
  });

  group('the SQL text (D9)', () {
    test('db.query.text is absent by default', () async {
      await withinServerSpan(() async => clientFor().query(selectUsers));

      expect(
        spans.findSpanByName('SELECT cuenta')!.attributes.getString('db.query.text'),
        isNull,
      );
    });

    test('db.query.text is present when explicitly opted in', () async {
      await withinServerSpan(
        () async => clientFor(
          options: const DbTracingOptions(includeQueryText: true),
        ).query(selectUsers),
      );

      expect(
        spans.findSpanByName('SELECT cuenta')!.attributes.getString('db.query.text'),
        equals('SELECT id, dni FROM cuenta WHERE dni = @dni'),
      );
    });

    test('parameter values are never recorded, even when the text is', () async {
      // The text is a template; the parameters are the data. Opting into one must not opt into
      // the other, or D9's protection would be pointless for a parameterised query.
      await withinServerSpan(
        () async => clientFor(
          options: const DbTracingOptions(includeQueryText: true),
        ).query(selectUsers),
      );

      final attributes = spans.findSpanByName('SELECT cuenta')!.attributes;

      for (final attribute in attributes.toList()) {
        expect(attribute.value.toString(), isNot(contains('12345678')));
      }
    });
  });

  group('failures', () {
    const failure = DbFailure(
      kind: DbFailureKind.timeout,
      code: '57014',
      message: 'canceling statement due to statement timeout',
      retryable: true,
      transient: true,
    );

    test('a failed command sets error status and records the failure kind', () async {
      // Failures arrive as a `DbResult`, not as a thrown exception, so the span has to inspect
      // the result. A decorator that only wrapped a try/catch would report every timeout as OK.
      await withinServerSpan(() async => clientFor(failure: failure).query(selectUsers));

      final span = spans.findSpanByName('SELECT cuenta')!;

      expect(span.status, equals(SpanStatusCode.Error));
      expect(span.attributes.getString('db.response.status_code'), equals('57014'));
      expect(span.attributes.getString('modular_api.db.failure_kind'), equals('timeout'));
    });

    test('the failure message is not copied into the span', () async {
      // A driver message can quote the offending row. The code and kind are enough to diagnose.
      await withinServerSpan(
        () async => clientFor(
          failure: const DbFailure(
            kind: DbFailureKind.constraint,
            code: '23505',
            message: 'duplicate key value violates unique constraint: dni=12345678',
            retryable: false,
            transient: false,
          ),
        ).query(selectUsers),
      );

      final span = spans.findSpanByName('SELECT cuenta')!;

      for (final attribute in span.attributes.toList()) {
        expect(attribute.value.toString(), isNot(contains('12345678')));
      }
    });

    test('the span is still ended when the command fails', () async {
      await withinServerSpan(() async => clientFor(failure: failure).query(selectUsers));

      expect(spans.findSpanByName('SELECT cuenta')!.endTime, isNotNull);
    });
  });

  group('transactions', () {
    test('a transaction span wraps the body', () async {
      await withinServerSpan(
        () async => clientFor().transaction<int>((context) async {
          await context.query(selectUsers);
          return DbResult<int>.success(1);
        }),
      );

      expect(spans.spanNames, contains('TRANSACTION socia'));
    });

    test('commands inside the body nest under the transaction span', () async {
      // This is what the decorator buys us: `DbTransactionContext` is built inside
      // `DbClient.transaction` from the same executor, so wrapping the executor once covers
      // commands issued through the transaction context as well.
      await withinServerSpan(
        () async => clientFor().transaction<int>((context) async {
          await context.query(selectUsers);
          return DbResult<int>.success(1);
        }),
      );

      final transaction = spans.findSpanByName('TRANSACTION socia')!;
      final command = spans.findSpanByName('SELECT cuenta')!;

      expect(
        command.spanContext.parentSpanId?.hexString,
        equals(transaction.spanContext.spanId.hexString),
      );
    });

    test('a failed transaction sets error status on the transaction span', () async {
      await withinServerSpan(
        () async => clientFor().transaction<int>(
          (context) async => DbResult<int>.failure(
            const DbFailure(
              kind: DbFailureKind.serialization,
              code: '40001',
              message: 'could not serialize access',
              retryable: true,
              transient: true,
            ),
          ),
        ),
      );

      final transaction = spans.findSpanByName('TRANSACTION socia')!;

      expect(transaction.status, equals(SpanStatusCode.Error));
      expect(
        transaction.attributes.getString('modular_api.db.failure_kind'),
        equals('serialization'),
      );
    });
  });

  group('session acquisition (D28)', () {
    test('acquiring a session produces its own span', () async {
      // The number that separates "the query was slow" from "we queued for a connection".
      // Without it, pool wait time lands in no span at all — an unattributed gap that reads as
      // nothing having happened.
      await withinServerSpan(() async => clientFor().query(selectUsers));

      expect(spans.spanNames, contains('CONNECT socia'));
    });

    test('the acquisition span precedes the command span', () async {
      await withinServerSpan(() async => clientFor().query(selectUsers));

      final connect = spans.findSpanByName('CONNECT socia')!;
      final command = spans.findSpanByName('SELECT cuenta')!;

      expect(connect.endTime!.isAfter(command.startTime), isFalse);
    });

    test('a failed acquisition is an error, and no command span follows', () async {
      final client = traceDbClient(
        DbClient<String>(
          settings: settings,
          sessionProvider: _FakeSessionProvider(
            settings,
            failure: const DbFailure(
              kind: DbFailureKind.connectivity,
              code: 'pool_exhausted',
              message: 'no connection available',
              retryable: true,
              transient: true,
            ),
          ),
          commandExecutor: _FakeCommandExecutor(),
          transactionRunner: _FakeTransactionRunner<String>(),
        ),
      );

      await withinServerSpan(() async => client.query(selectUsers));

      expect(spans.findSpanByName('CONNECT socia')!.status, equals(SpanStatusCode.Error));
      expect(spans.spanNames, isNot(contains('SELECT cuenta')));
    });
  });

  group('without tracing configured (G3)', () {
    test('an unwrapped client produces no spans', () async {
      // Instrumentation is opt-in by construction: not wrapping is how you turn it off, so the
      // cost of not using it is exactly zero rather than a branch per call.
      await withinServerSpan(
        () async => DbClient<String>(
          settings: settings,
          sessionProvider: _FakeSessionProvider(settings),
          commandExecutor: _FakeCommandExecutor(),
          transactionRunner: _FakeTransactionRunner<String>(),
        ).query(selectUsers),
      );

      expect(spans.spanNames, isNot(contains('SELECT cuenta')));
    });

    test('a wrapped client with no active span emits nothing', () async {
      // No recording parent means the request was not sampled, or tracing is off entirely.
      await clientFor().query(selectUsers);

      expect(spans.spans, isEmpty);
    });

    test('the call still succeeds with no active span', () async {
      final result = await clientFor().query(selectUsers);

      expect(result.isSuccess, isTrue);
    });

    test('wrapping preserves the provider description and settings', () async {
      // The wrapped client must be a drop-in replacement, including for the health contributor
      // and GraphQL support that read `describe()`.
      final client = clientFor();

      expect(client.describe().engineId, equals('postgres'));
      expect(client.settings.database, equals('socia'));
    });
  });
}

class _FakeSessionProvider implements DbSessionProvider<String> {
  _FakeSessionProvider(this.settings, {this.failure});

  final DbConnectionSettings settings;
  final DbFailure? failure;

  @override
  Future<DbResult<DbSessionLease<String>>> acquire() async {
    if (failure != null) {
      return DbResult<DbSessionLease<String>>.failure(failure!);
    }
    return DbResult<DbSessionLease<String>>.success(
      DbSessionLease<String>(
        session: 'session',
        ownedByPackage: true,
        releaser: () async => DbResult<void>.success(null),
      ),
    );
  }

  @override
  Future<DbResult<void>> close() async => DbResult<void>.success(null);

  @override
  DbProviderDescription describe() => DbProviderDescription(
        engineId: settings.engineId,
        database: settings.database,
        redactedSummary: settings.redactedSummary,
        ownsResources: true,
      );
}

class _FakeCommandExecutor implements DbCommandExecutor<String> {
  _FakeCommandExecutor({this.failure});

  final DbFailure? failure;

  static const _metadata = DbExecutionMetadata(
    duration: Duration(milliseconds: 2),
    rowCount: 1,
    affectedCount: 1,
  );

  @override
  Future<DbResult<DbRowSet>> query(String session, DbCommand command) async {
    if (failure != null) return DbResult<DbRowSet>.failure(failure!);
    return DbResult<DbRowSet>.success(
      const DbRowSet(rows: [{'id': 1}], metadata: _metadata),
    );
  }

  @override
  Future<DbResult<DbExecutionSummary>> execute(String session, DbCommand command) async {
    if (failure != null) return DbResult<DbExecutionSummary>.failure(failure!);
    return DbResult<DbExecutionSummary>.success(
      const DbExecutionSummary(affectedCount: 1, metadata: _metadata),
    );
  }

  @override
  Future<DbResult<DbScalar<T>>> scalar<T>(String session, DbCommand command) async {
    if (failure != null) return DbResult<DbScalar<T>>.failure(failure!);
    return DbResult<DbScalar<T>>.success(
      DbScalar<T>(value: 1 as T, metadata: _metadata),
    );
  }
}

class _FakeTransactionRunner<S> implements DbTransactionRunner<S> {
  @override
  Future<DbResult<T>> run<T>(
    DbTransactionContext<S> context,
    Future<DbResult<T>> Function(DbTransactionContext<S> context) body,
  ) =>
      body(context);
}
