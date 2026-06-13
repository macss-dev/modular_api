import 'package:modular_api_postgres/modular_api_postgres.dart';
import 'package:test/test.dart';

void main() {
  group('DbConnectionSettings', () {
    test('normalizes environment defaults and redacts secrets', () {
      final settings = DbConnectionSettings.fromEnvironment(
        environment: const {
          'MODULAR_API_POSTGRES_HOST': 'db.local',
          'MODULAR_API_POSTGRES_PASSWORD': 'super-secret',
        },
      );

      expect(settings.engineId, 'postgres');
      expect(settings.host, 'db.local');
      expect(settings.port, 5432);
      expect(settings.database, 'modular_api_graphql_v1');
      expect(settings.username, 'postgres');
      expect(settings.password, 'super-secret');
      expect(settings.sslMode, 'disable');
      expect(settings.redactedSummary, contains('db.local:5432'));
      expect(settings.redactedSummary, contains('postgres@'));
      expect(settings.redactedSummary, contains('sslmode=disable'));
      expect(settings.redactedSummary, isNot(contains('super-secret')));
    });
  });

  group('DbResult', () {
    test('supports map, flatMap, mapFailure and getOrThrow', () {
      final success = DbResult<int>.success(21);
      final failure = DbResult<int>.failure(
        const DbFailure(
          kind: DbFailureKind.timeout,
          code: 'timeout',
          message: 'Timed out',
          retryable: true,
          transient: true,
        ),
      );

      expect(success.map((value) => value * 2).value, 42);
      expect(
        success.flatMap((value) => DbResult<int>.success(value + 1)).value,
        22,
      );

      final mappedFailure = failure.mapFailure(
        (current) => DbFailure(
          kind: current.kind,
          code: 'wrapped_timeout',
          message: current.message,
          retryable: current.retryable,
          transient: current.transient,
        ),
      );

      expect(mappedFailure.failure.code, 'wrapped_timeout');
      expect(success.getOrThrow(), 21);
      expect(() => failure.getOrThrow(), throwsStateError);
    });
  });

  group('DbClient', () {
    test('delegates query calls and releases package-owned leases', () async {
      final settings = DbConnectionSettings.fromEnvironment();
      final provider = _FakeSessionProvider(settings, session: 'db-session');
      final executor = _FakeCommandExecutor(
        rowSet: DbRowSet(
          rows: const [
            {'id': 1},
          ],
          metadata: const DbExecutionMetadata(
            duration: Duration(milliseconds: 3),
            commandLabel: 'users.list',
            rowCount: 1,
          ),
        ),
      );
      final client = DbClient<String>(
        settings: settings,
        sessionProvider: provider,
        commandExecutor: executor,
        transactionRunner: _FakeTransactionRunner(),
      );

      final result = await client.query(
        const DbCommand(
          kind: DbCommandKind.query,
          text: 'select id from users',
          label: 'users.list',
        ),
      );

      expect(result.isSuccess, isTrue);
      expect(result.value.rows, [
        {'id': 1},
      ]);
      expect(result.value.metadata.rowCount, 1);
      expect(provider.acquireCount, 1);
      expect(provider.releaseCount, 1);
      expect(executor.lastSession, 'db-session');
      expect(executor.lastCommand?.label, 'users.list');
    });

    test('returns a failure when session acquisition fails', () async {
      final settings = DbConnectionSettings.fromEnvironment();
      final provider = _FakeSessionProvider(
        settings,
        acquireFailure: const DbFailure(
          kind: DbFailureKind.connectivity,
          code: 'connect_failed',
          message: 'Could not connect',
          retryable: true,
          transient: true,
        ),
      );
      final client = DbClient<String>(
        settings: settings,
        sessionProvider: provider,
        commandExecutor: _FakeCommandExecutor(),
        transactionRunner: _FakeTransactionRunner(),
      );

      final result = await client.query(
        const DbCommand(kind: DbCommandKind.query, text: 'select 1'),
      );

      expect(result.isFailure, isTrue);
      expect(result.failure.code, 'connect_failed');
    });

    test(
      'returns a failure when releasing a package-owned lease fails',
      () async {
        final settings = DbConnectionSettings.fromEnvironment();
        final provider = _FakeSessionProvider(
          settings,
          releaseFailure: const DbFailure(
            kind: DbFailureKind.unknown,
            code: 'release_failed',
            message: 'Release failed',
            retryable: false,
            transient: false,
          ),
        );
        final client = DbClient<String>(
          settings: settings,
          sessionProvider: provider,
          commandExecutor: _FakeCommandExecutor(),
          transactionRunner: _FakeTransactionRunner(),
        );

        final result = await client.query(
          const DbCommand(kind: DbCommandKind.query, text: 'select 1'),
        );

        expect(result.isFailure, isTrue);
        expect(result.failure.code, 'release_failed');
      },
    );

    test('does not release application-owned leases', () async {
      final settings = DbConnectionSettings.fromEnvironment();
      final provider = _FakeSessionProvider(settings, ownedByPackage: false);
      final executor = _FakeCommandExecutor(
        executionSummary: const DbExecutionSummary(
          affectedCount: 1,
          metadata: DbExecutionMetadata(
            duration: Duration(milliseconds: 2),
            commandLabel: 'users.touch',
            affectedCount: 1,
          ),
        ),
      );
      final client = DbClient<String>(
        settings: settings,
        sessionProvider: provider,
        commandExecutor: executor,
        transactionRunner: _FakeTransactionRunner(),
      );

      final result = await client.execute(
        const DbCommand(
          kind: DbCommandKind.execute,
          text: 'update users set touched = true',
          label: 'users.touch',
        ),
      );

      expect(result.isSuccess, isTrue);
      expect(result.value.affectedCount, 1);
      expect(provider.releaseCount, 0);
    });

    test('commits successful transactions and rolls back failed ones', () async {
      final settings = DbConnectionSettings.fromEnvironment();
      final provider = _FakeSessionProvider(settings);
      final executor = _FakeCommandExecutor(scalarValue: 7);
      final runner = _FakeTransactionRunner();
      final client = DbClient<String>(
        settings: settings,
        sessionProvider: provider,
        commandExecutor: executor,
        transactionRunner: runner,
      );

      final success = await client.transaction<int>((transaction) async {
        final scalarResult = await transaction.scalar<int>(
          const DbCommand(
            kind: DbCommandKind.scalar,
            text: 'select count(*) from users',
            label: 'users.count',
          ),
        );
        return scalarResult.map((value) => value.value);
      });

      final failure = await client.transaction<int>((_) async {
        return DbResult<int>.failure(
          const DbFailure(
            kind: DbFailureKind.conflict,
            code: 'duplicate_key',
            message: 'Duplicate key',
            retryable: false,
            transient: false,
          ),
        );
      });

      expect(success.isSuccess, isTrue);
      expect(success.value, 7);
      expect(failure.isFailure, isTrue);
      expect(failure.failure.code, 'duplicate_key');
      expect(runner.commitCount, 1);
      expect(runner.rollbackCount, 1);
      expect(provider.releaseCount, 2);
    });

    test('describes its provider and closes cleanly', () async {
      final settings = DbConnectionSettings.fromEnvironment();
      final provider = _FakeSessionProvider(settings);
      final client = DbClient<String>(
        settings: settings,
        sessionProvider: provider,
        commandExecutor: _FakeCommandExecutor(),
        transactionRunner: _FakeTransactionRunner(),
      );

      expect(client.describe().engineId, 'postgres');
      expect(client.describe().database, settings.database);

      final closed = await client.close();
      expect(closed.isSuccess, isTrue);
      expect(provider.closeCount, 1);
    });

    test('propagates provider close failures', () async {
      final settings = DbConnectionSettings.fromEnvironment();
      final provider = _FakeSessionProvider(
        settings,
        closeFailure: const DbFailure(
          kind: DbFailureKind.unknown,
          code: 'close_failed',
          message: 'Close failed',
          retryable: false,
          transient: false,
        ),
      );
      final client = DbClient<String>(
        settings: settings,
        sessionProvider: provider,
        commandExecutor: _FakeCommandExecutor(),
        transactionRunner: _FakeTransactionRunner(),
      );

      final closed = await client.close();

      expect(closed.isFailure, isTrue);
      expect(closed.failure.code, 'close_failed');
    });
  });

  group('DbRepository and health', () {
    test('keeps repository helpers thin over the shared context', () async {
      final settings = DbConnectionSettings.fromEnvironment();
      final provider = _FakeSessionProvider(settings);
      final executor = _FakeCommandExecutor(scalarValue: 9);
      final context = DbRepositoryContext<String>(
        settings: settings,
        sessionProvider: provider,
        commandExecutor: executor,
        transactionRunner: _FakeTransactionRunner(),
      );
      final repository = _UserStatsRepository(context);

      final result = await repository.totalUsers();

      expect(result.isSuccess, isTrue);
      expect(result.value, 9);
      expect(executor.lastCommand?.label, 'users.count');
    });

    test('probes health and bundles GraphQL support dependencies', () async {
      final settings = DbConnectionSettings.fromEnvironment();
      final provider = _FakeSessionProvider(settings);
      final executor = _FakeCommandExecutor(scalarValue: 1);
      final client = DbClient<String>(
        settings: settings,
        sessionProvider: provider,
        commandExecutor: executor,
        transactionRunner: _FakeTransactionRunner(),
      );
      final healthContributor = DbHealthContributor<String>(client: client);
      final support = DbGraphqlSupport<String>(
        catalogProvider: 'catalog-provider',
        readExecutor: 'read-executor',
        healthContributor: healthContributor,
      );

      final report = await healthContributor.probe();

      expect(report.status, DbHealthStatus.healthy);
      expect(report.redactedSummary, settings.redactedSummary);
      expect(report.responseTime, greaterThanOrEqualTo(Duration.zero));
      expect(support.catalogProvider, 'catalog-provider');
      expect(support.readExecutor, 'read-executor');
      expect(support.healthContributor, healthContributor);
    });

    test('reports unhealthy health probes when scalar execution fails', () async {
      final settings = DbConnectionSettings.fromEnvironment();
      final provider = _FakeSessionProvider(settings);
      final executor = _FakeCommandExecutor(
        failure: const DbFailure(
          kind: DbFailureKind.timeout,
          code: 'timeout',
          message: 'Timed out',
          retryable: true,
          transient: true,
        ),
      );
      final client = DbClient<String>(
        settings: settings,
        sessionProvider: provider,
        commandExecutor: executor,
        transactionRunner: _FakeTransactionRunner(),
      );
      final healthContributor = DbHealthContributor<String>(client: client);

      final report = await healthContributor.probe();

      expect(report.status, DbHealthStatus.unhealthy);
      expect(report.details, 'timeout');
    });
  });

  group('DbParameter (0.6.0 typed parameters)', () {
    test('input() captures name, value and an optional free-form type hint', () {
      final plain = DbParameter.input('id', 42);
      expect(plain.name, 'id');
      expect(plain.value, 42);
      expect(plain.direction, DbParameterDirection.input);
      expect(plain.typeHint, isNull);

      final hinted = DbParameter.input('payload', [1, 2, 3], 'bytea');
      expect(hinted.direction, DbParameterDirection.input);
      expect(hinted.typeHint, 'bytea');
    });

    test('output() carries no input value and defaults its direction', () {
      final out = DbParameter.output('total', 'integer');
      expect(out.name, 'total');
      expect(out.value, isNull);
      expect(out.direction, DbParameterDirection.output);
      expect(out.typeHint, 'integer');
    });

    test('inputOutput() marks bidirectional parameters', () {
      final io = DbParameter.inputOutput('counter', 1, 'integer');
      expect(io.direction, DbParameterDirection.inputOutput);
      expect(io.value, 1);
    });

    test('defaults the direction to input when constructed directly', () {
      const param = DbParameter(name: 'name', value: 'foto.jpg');
      expect(param.direction, DbParameterDirection.input);
    });

    test('flows through DbCommand.parameters unchanged', () {
      const command = DbCommand(
        kind: DbCommandKind.procedure,
        text: 'fn_eliminar_foto',
        parameters: [
          DbParameter(name: 'nombre', value: 'foto.jpg'),
          'positional-still-allowed',
        ],
      );
      expect(command.parameters, hasLength(2));
      expect(command.parameters[0], isA<DbParameter>());
      expect((command.parameters[0]! as DbParameter).name, 'nombre');
      expect(command.parameters[1], 'positional-still-allowed');
    });
  });

  group('DbCommandKind.procedure (0.6.0)', () {
    test('exposes the new procedure kind', () {
      expect(DbCommandKind.values, contains(DbCommandKind.procedure));
    });
  });

  group('DbProcedureOutcome (0.6.0)', () {
    test('carries an engine-agnostic return value and output parameters', () {
      const outcome = DbProcedureOutcome(
        returnValue: 0,
        outputParameters: {'total': 5},
      );
      expect(outcome.returnValue, 0);
      expect(outcome.outputParameters, {'total': 5});
    });

    test('allows both fields to be absent', () {
      const empty = DbProcedureOutcome();
      expect(empty.returnValue, isNull);
      expect(empty.outputParameters, isNull);
    });

    test('attaches optionally to DbRowSet without breaking existing construction', () {
      const withoutOutcome = DbRowSet(
        rows: [{'id': 1}],
        metadata: DbExecutionMetadata(duration: Duration(milliseconds: 1)),
      );
      expect(withoutOutcome.procedure, isNull);

      const withOutcome = DbRowSet(
        rows: [{'id': 1}],
        metadata: DbExecutionMetadata(duration: Duration(milliseconds: 1)),
        procedure: DbProcedureOutcome(returnValue: 0),
      );
      expect(withOutcome.procedure?.returnValue, 0);
    });

    test('attaches optionally to DbExecutionSummary without breaking existing construction', () {
      const withoutOutcome = DbExecutionSummary(
        affectedCount: 1,
        metadata: DbExecutionMetadata(duration: Duration(milliseconds: 1)),
      );
      expect(withoutOutcome.procedure, isNull);

      const withOutcome = DbExecutionSummary(
        affectedCount: 1,
        metadata: DbExecutionMetadata(duration: Duration(milliseconds: 1)),
        procedure: DbProcedureOutcome(outputParameters: {'id': 99}),
      );
      expect(withOutcome.procedure?.outputParameters, {'id': 99});
    });
  });
}

final class _FakeSessionProvider implements DbSessionProvider<String> {
  _FakeSessionProvider(
    this.settings, {
    this.session = 'session-1',
    this.ownedByPackage = true,
    this.acquireFailure,
    this.releaseFailure,
    this.closeFailure,
  });

  final DbConnectionSettings settings;
  final String session;
  final bool ownedByPackage;
  final DbFailure? acquireFailure;
  final DbFailure? releaseFailure;
  final DbFailure? closeFailure;

  int acquireCount = 0;
  int releaseCount = 0;
  int closeCount = 0;

  @override
  Future<DbResult<DbSessionLease<String>>> acquire() async {
    acquireCount += 1;
    if (acquireFailure case final failure?) {
      return DbResult<DbSessionLease<String>>.failure(failure);
    }

    return DbResult<DbSessionLease<String>>.success(
      DbSessionLease<String>(
        session: session,
        ownedByPackage: ownedByPackage,
        releaser: () async {
          releaseCount += 1;
          if (releaseFailure case final failure?) {
            return DbResult<void>.failure(failure);
          }
          return DbResult<void>.success(null);
        },
      ),
    );
  }

  @override
  Future<DbResult<void>> close() async {
    closeCount += 1;
    if (closeFailure case final failure?) {
      return DbResult<void>.failure(failure);
    }
    return DbResult<void>.success(null);
  }

  @override
  DbProviderDescription describe() {
    return DbProviderDescription(
      engineId: settings.engineId,
      database: settings.database,
      redactedSummary: settings.redactedSummary,
      ownsResources: ownedByPackage,
    );
  }
}

final class _FakeCommandExecutor implements DbCommandExecutor<String> {
  _FakeCommandExecutor({
    DbRowSet? rowSet,
    DbExecutionSummary? executionSummary,
    this.scalarValue,
    this.failure,
  }) : rowSet =
           rowSet ??
               DbRowSet(
                 rows: const [],
                 metadata: const DbExecutionMetadata(duration: Duration.zero),
               ),
       executionSummary =
           executionSummary ??
               const DbExecutionSummary(
                 affectedCount: 0,
                 metadata: DbExecutionMetadata(duration: Duration.zero),
               );

  final DbRowSet rowSet;
  final DbExecutionSummary executionSummary;
  final Object? scalarValue;
  final DbFailure? failure;

  String? lastSession;
  DbCommand? lastCommand;

  @override
  Future<DbResult<DbExecutionSummary>> execute(
    String session,
    DbCommand command,
  ) async {
    lastSession = session;
    lastCommand = command;
    if (failure case final current?) {
      return DbResult<DbExecutionSummary>.failure(current);
    }
    return DbResult<DbExecutionSummary>.success(executionSummary);
  }

  @override
  Future<DbResult<DbRowSet>> query(String session, DbCommand command) async {
    lastSession = session;
    lastCommand = command;
    if (failure case final current?) {
      return DbResult<DbRowSet>.failure(current);
    }
    return DbResult<DbRowSet>.success(rowSet);
  }

  @override
  Future<DbResult<DbScalar<T>>> scalar<T>(
    String session,
    DbCommand command,
  ) async {
    lastSession = session;
    lastCommand = command;
    if (failure case final current?) {
      return DbResult<DbScalar<T>>.failure(current);
    }
    return DbResult<DbScalar<T>>.success(
      DbScalar<T>(
        value: scalarValue as T,
        metadata: DbExecutionMetadata(
          duration: Duration.zero,
          commandLabel: command.label,
        ),
      ),
    );
  }
}

final class _FakeTransactionRunner implements DbTransactionRunner<String> {
  int commitCount = 0;
  int rollbackCount = 0;

  @override
  Future<DbResult<T>> run<T>(
    DbTransactionContext<String> context,
    Future<DbResult<T>> Function(DbTransactionContext<String> context) body,
  ) async {
    final result = await body(context);
    if (result.isSuccess) {
      commitCount += 1;
    } else {
      rollbackCount += 1;
    }
    return result;
  }
}

final class _UserStatsRepository extends DbRepository<String> {
  const _UserStatsRepository(super.context);

  Future<DbResult<int>> totalUsers() async {
    final result = await scalar<int>(
      const DbCommand(
        kind: DbCommandKind.scalar,
        text: 'select count(*) from users',
        label: 'users.count',
      ),
    );
    return result.map((value) => value.value);
  }
}