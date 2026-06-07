import {
  DbClient,
  DbCommand,
  DbCommandExecutor,
  DbCommandKind,
  DbConnectionSettings,
  DbExecutionMetadata,
  DbExecutionSummary,
  DbProviderDescription,
  DbResult,
  DbRowSet,
  DbScalar,
  DbSessionLease,
  DbSessionProvider,
  DbTransactionContext,
  DbTransactionRunner,
} from '../src';

async function main(): Promise<void> {
  const settings = DbConnectionSettings.fromEnvironment({
    MODULAR_API_POSTGRES_HOST: 'db.local',
    MODULAR_API_POSTGRES_PASSWORD: 'not-printed',
  });

  const client = new DbClient<string>({
    settings,
    sessionProvider: new FakeSessionProvider(settings),
    commandExecutor: new FakeCommandExecutor(),
    transactionRunner: new PassthroughTransactionRunner(),
  });

  const result = await client.scalar<number>(
    new DbCommand({
      kind: DbCommandKind.scalar,
      text: 'select count(*) from users',
      label: 'users.count',
    }),
  );

  if (result.isSuccess) {
    console.log(`Total users: ${result.value.value}`);
    return;
  }

  console.error(result.failure.message);
}

class FakeSessionProvider implements DbSessionProvider<string> {
  public constructor(private readonly settings: DbConnectionSettings) {}

  public async acquire(): Promise<DbResult<DbSessionLease<string>>> {
    return DbResult.success(
      new DbSessionLease({
        session: 'session-1',
        ownedByPackage: true,
        releaser: async () => DbResult.success<void>(undefined),
      }),
    );
  }

  public async close(): Promise<DbResult<void>> {
    return DbResult.success<void>(undefined);
  }

  public describe(): DbProviderDescription {
    return new DbProviderDescription({
      engineId: this.settings.engineId,
      database: this.settings.database,
      redactedSummary: this.settings.redactedSummary,
      ownsResources: true,
    });
  }
}

class FakeCommandExecutor implements DbCommandExecutor<string> {
  public async query(_session: string, _command: DbCommand): Promise<DbResult<DbRowSet>> {
    return DbResult.success(
      new DbRowSet({
        rows: [{ id: 1 }],
        metadata: new DbExecutionMetadata({
          duration: 0,
          rowCount: 1,
        }),
      }),
    );
  }

  public async execute(
    _session: string,
    _command: DbCommand,
  ): Promise<DbResult<DbExecutionSummary>> {
    return DbResult.success(
      new DbExecutionSummary({
        affectedCount: 1,
        metadata: new DbExecutionMetadata({ duration: 0 }),
      }),
    );
  }

  public async scalar<T>(_session: string, command: DbCommand): Promise<DbResult<DbScalar<T>>> {
    return DbResult.success(
      new DbScalar<T>({
        value: 42 as T,
        metadata: new DbExecutionMetadata({
          duration: 0,
          commandLabel: command.label,
        }),
      }),
    );
  }
}

class PassthroughTransactionRunner implements DbTransactionRunner<string> {
  public run<T>(
    context: DbTransactionContext<string>,
    body: (context: DbTransactionContext<string>) => Promise<DbResult<T>>,
  ): Promise<DbResult<T>> {
    return body(context);
  }
}

void main();