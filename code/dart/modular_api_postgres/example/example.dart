import 'package:modular_api_postgres/modular_api_postgres.dart';

Future<void> main() async {
  final settings = DbConnectionSettings.fromEnvironment(
    environment: const {
      'MODULAR_API_POSTGRES_HOST': 'db.local',
      'MODULAR_API_POSTGRES_PASSWORD': 'not-printed',
    },
  );

  final client = DbClient<String>(
    settings: settings,
    sessionProvider: _FakeSessionProvider(settings),
    commandExecutor: const _FakeCommandExecutor(),
    transactionRunner: const _PassthroughTransactionRunner(),
  );

  final result = await client.scalar<int>(
    const DbCommand(
      kind: DbCommandKind.scalar,
      text: 'select count(*) from users',
      label: 'users.count',
    ),
  );

  if (result.isSuccess) {
    print('Total users: ${result.value.value}');
    return;
  }

  print(result.failure.message);
}

final class _FakeSessionProvider implements DbSessionProvider<String> {
  const _FakeSessionProvider(this.settings);

  final DbConnectionSettings settings;

  @override
  Future<DbResult<DbSessionLease<String>>> acquire() async {
    return DbResult<DbSessionLease<String>>.success(
      DbSessionLease<String>(
        session: 'session-1',
        ownedByPackage: true,
        releaser: () async => DbResult<void>.success(null),
      ),
    );
  }

  @override
  Future<DbResult<void>> close() async {
    return DbResult<void>.success(null);
  }

  @override
  DbProviderDescription describe() {
    return DbProviderDescription(
      engineId: settings.engineId,
      database: settings.database,
      redactedSummary: settings.redactedSummary,
      ownsResources: true,
    );
  }
}

final class _FakeCommandExecutor implements DbCommandExecutor<String> {
  const _FakeCommandExecutor();

  @override
  Future<DbResult<DbExecutionSummary>> execute(
    String session,
    DbCommand command,
  ) async {
    return DbResult<DbExecutionSummary>.success(
      DbExecutionSummary(
        affectedCount: 1,
        metadata: DbExecutionMetadata(duration: Duration.zero),
      ),
    );
  }

  @override
  Future<DbResult<DbRowSet>> query(String session, DbCommand command) async {
    return DbResult<DbRowSet>.success(
      DbRowSet(
        rows: const [
          {'id': 1},
        ],
        metadata: const DbExecutionMetadata(
          duration: Duration.zero,
          rowCount: 1,
        ),
      ),
    );
  }

  @override
  Future<DbResult<DbScalar<T>>> scalar<T>(
    String session,
    DbCommand command,
  ) async {
    return DbResult<DbScalar<T>>.success(
      DbScalar<T>(
        value: 42 as T,
        metadata: DbExecutionMetadata(
          duration: Duration.zero,
          commandLabel: command.label,
        ),
      ),
    );
  }
}

final class _PassthroughTransactionRunner
    implements DbTransactionRunner<String> {
  const _PassthroughTransactionRunner();

  @override
  Future<DbResult<T>> run<T>(
    DbTransactionContext<String> context,
    Future<DbResult<T>> Function(DbTransactionContext<String> context) body,
  ) {
    return body(context);
  }
}