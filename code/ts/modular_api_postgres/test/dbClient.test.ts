import {
  DbClient,
  DbCommand,
  DbCommandKind,
  DbConnectionSettings,
  DbExecutionMetadata,
  DbExecutionSummary,
  DbFailure,
  DbFailureKind,
  DbGraphqlSupport,
  DbHealthContributor,
  DbHealthStatus,
  DbProviderDescription,
  DbRepository,
  DbRepositoryContext,
  DbResult,
  DbRowSet,
  DbScalar,
  DbSessionLease,
  type DbCommandExecutor,
  type DbSessionProvider,
  type DbTransactionContext,
  type DbTransactionRunner,
} from '../src';

import { describe, expect, it } from 'vitest';

describe('DbConnectionSettings', () => {
  it('normalizes environment defaults and redacts secrets', () => {
    const settings = DbConnectionSettings.fromEnvironment({
      MODULAR_API_POSTGRES_HOST: 'db.local',
      MODULAR_API_POSTGRES_PASSWORD: 'super-secret',
    });

    expect(settings.engineId).toBe('postgres');
    expect(settings.host).toBe('db.local');
    expect(settings.port).toBe(5432);
    expect(settings.database).toBe('modular_api_graphql_v1');
    expect(settings.username).toBe('postgres');
    expect(settings.password).toBe('super-secret');
    expect(settings.sslMode).toBe('disable');
    expect(settings.redactedSummary).toContain('db.local:5432');
    expect(settings.redactedSummary).toContain('postgres@');
    expect(settings.redactedSummary).toContain('sslmode=disable');
    expect(settings.redactedSummary).not.toContain('super-secret');
  });
});

describe('DbResult', () => {
  it('supports map, flatMap, mapFailure and getOrThrow', () => {
    const success = DbResult.success(21);
    const failure = DbResult.failure<number>(
      new DbFailure({
        kind: DbFailureKind.timeout,
        code: 'timeout',
        message: 'Timed out',
        retryable: true,
        transient: true,
      }),
    );

    expect(success.map((value) => value * 2).value).toBe(42);
    expect(success.flatMap((value) => DbResult.success(value + 1)).value).toBe(22);

    const mappedFailure = failure.mapFailure(
      (current) =>
        new DbFailure({
          kind: current.kind,
          code: 'wrapped_timeout',
          message: current.message,
          retryable: current.retryable,
          transient: current.transient,
        }),
    );

    expect(mappedFailure.failure.code).toBe('wrapped_timeout');
    expect(success.getOrThrow()).toBe(21);
    expect(() => failure.getOrThrow()).toThrowError();
  });
});

describe('DbClient', () => {
  it('delegates query calls and releases package-owned leases', async () => {
    const settings = DbConnectionSettings.fromEnvironment();
    const provider = new FakeSessionProvider(settings, { session: 'db-session' });
    const executor = new FakeCommandExecutor({
      rowSet: new DbRowSet({
        rows: [{ id: 1 }],
        metadata: new DbExecutionMetadata({
          duration: 3,
          commandLabel: 'users.list',
          rowCount: 1,
        }),
      }),
    });
    const client = new DbClient({
      settings,
      sessionProvider: provider,
      commandExecutor: executor,
      transactionRunner: new FakeTransactionRunner(),
    });

    const result = await client.query(
      new DbCommand({
        kind: DbCommandKind.query,
        text: 'select id from users',
        label: 'users.list',
      }),
    );

    expect(result.isSuccess).toBe(true);
    expect(result.value.rows).toEqual([{ id: 1 }]);
    expect(result.value.metadata.rowCount).toBe(1);
    expect(provider.acquireCount).toBe(1);
    expect(provider.releaseCount).toBe(1);
    expect(executor.lastSession).toBe('db-session');
    expect(executor.lastCommand?.label).toBe('users.list');
  });

  it('returns a failure when session acquisition fails', async () => {
    const settings = DbConnectionSettings.fromEnvironment();
    const provider = new FakeSessionProvider(settings, {
      acquireFailure: new DbFailure({
        kind: DbFailureKind.connectivity,
        code: 'connect_failed',
        message: 'Could not connect',
        retryable: true,
        transient: true,
      }),
    });
    const client = new DbClient({
      settings,
      sessionProvider: provider,
      commandExecutor: new FakeCommandExecutor(),
      transactionRunner: new FakeTransactionRunner(),
    });

    const result = await client.query(
      new DbCommand({
        kind: DbCommandKind.query,
        text: 'select 1',
      }),
    );

    expect(result.isFailure).toBe(true);
    expect(result.failure.code).toBe('connect_failed');
  });

  it('returns a failure when releasing a package-owned lease fails', async () => {
    const settings = DbConnectionSettings.fromEnvironment();
    const provider = new FakeSessionProvider(settings, {
      releaseFailure: new DbFailure({
        kind: DbFailureKind.unknown,
        code: 'release_failed',
        message: 'Release failed',
        retryable: false,
        transient: false,
      }),
    });
    const client = new DbClient({
      settings,
      sessionProvider: provider,
      commandExecutor: new FakeCommandExecutor(),
      transactionRunner: new FakeTransactionRunner(),
    });

    const result = await client.query(
      new DbCommand({
        kind: DbCommandKind.query,
        text: 'select 1',
      }),
    );

    expect(result.isFailure).toBe(true);
    expect(result.failure.code).toBe('release_failed');
  });

  it('does not release application-owned leases', async () => {
    const settings = DbConnectionSettings.fromEnvironment();
    const provider = new FakeSessionProvider(settings, { ownedByPackage: false });
    const executor = new FakeCommandExecutor({
      executionSummary: new DbExecutionSummary({
        affectedCount: 1,
        metadata: new DbExecutionMetadata({
          duration: 2,
          commandLabel: 'users.touch',
          affectedCount: 1,
        }),
      }),
    });
    const client = new DbClient({
      settings,
      sessionProvider: provider,
      commandExecutor: executor,
      transactionRunner: new FakeTransactionRunner(),
    });

    const result = await client.execute(
      new DbCommand({
        kind: DbCommandKind.execute,
        text: 'update users set touched = true',
        label: 'users.touch',
      }),
    );

    expect(result.isSuccess).toBe(true);
    expect(result.value.affectedCount).toBe(1);
    expect(provider.releaseCount).toBe(0);
  });

  it('commits successful transactions and rolls back failed ones', async () => {
    const settings = DbConnectionSettings.fromEnvironment();
    const provider = new FakeSessionProvider(settings);
    const executor = new FakeCommandExecutor({ scalarValue: 7 });
    const runner = new FakeTransactionRunner();
    const client = new DbClient({
      settings,
      sessionProvider: provider,
      commandExecutor: executor,
      transactionRunner: runner,
    });

    const success = await client.transaction(async (transaction) => {
      const scalarResult = await transaction.scalar<number>(
        new DbCommand({
          kind: DbCommandKind.scalar,
          text: 'select count(*) from users',
          label: 'users.count',
        }),
      );
      return scalarResult.map((value) => value.value);
    });

    const failure = await client.transaction(async () =>
      DbResult.failure<number>(
        new DbFailure({
          kind: DbFailureKind.conflict,
          code: 'duplicate_key',
          message: 'Duplicate key',
          retryable: false,
          transient: false,
        }),
      ),
    );

    expect(success.isSuccess).toBe(true);
    expect(success.value).toBe(7);
    expect(failure.isFailure).toBe(true);
    expect(failure.failure.code).toBe('duplicate_key');
    expect(runner.commitCount).toBe(1);
    expect(runner.rollbackCount).toBe(1);
    expect(provider.releaseCount).toBe(2);
  });

  it('describes its provider and closes cleanly', async () => {
    const settings = DbConnectionSettings.fromEnvironment();
    const provider = new FakeSessionProvider(settings);
    const client = new DbClient({
      settings,
      sessionProvider: provider,
      commandExecutor: new FakeCommandExecutor(),
      transactionRunner: new FakeTransactionRunner(),
    });

    expect(client.describe().engineId).toBe('postgres');
    expect(client.describe().database).toBe(settings.database);

    const closed = await client.close();
    expect(closed.isSuccess).toBe(true);
    expect(provider.closeCount).toBe(1);
  });

  it('propagates provider close failures', async () => {
    const settings = DbConnectionSettings.fromEnvironment();
    const provider = new FakeSessionProvider(settings, {
      closeFailure: new DbFailure({
        kind: DbFailureKind.unknown,
        code: 'close_failed',
        message: 'Close failed',
        retryable: false,
        transient: false,
      }),
    });
    const client = new DbClient({
      settings,
      sessionProvider: provider,
      commandExecutor: new FakeCommandExecutor(),
      transactionRunner: new FakeTransactionRunner(),
    });

    const closed = await client.close();

    expect(closed.isFailure).toBe(true);
    expect(closed.failure.code).toBe('close_failed');
  });
});

describe('DbRepository and health', () => {
  it('keeps repository helpers thin over the shared context', async () => {
    const settings = DbConnectionSettings.fromEnvironment();
    const provider = new FakeSessionProvider(settings);
    const executor = new FakeCommandExecutor({ scalarValue: 9 });
    const context = new DbRepositoryContext({
      settings,
      sessionProvider: provider,
      commandExecutor: executor,
      transactionRunner: new FakeTransactionRunner(),
    });
    const repository = new UserStatsRepository(context);

    const result = await repository.totalUsers();

    expect(result.isSuccess).toBe(true);
    expect(result.value).toBe(9);
    expect(executor.lastCommand?.label).toBe('users.count');
  });

  it('probes health and bundles GraphQL support dependencies', async () => {
    const settings = DbConnectionSettings.fromEnvironment();
    const provider = new FakeSessionProvider(settings);
    const executor = new FakeCommandExecutor({ scalarValue: 1 });
    const client = new DbClient({
      settings,
      sessionProvider: provider,
      commandExecutor: executor,
      transactionRunner: new FakeTransactionRunner(),
    });
    const healthContributor = new DbHealthContributor({ client });
    const support = new DbGraphqlSupport({
      catalogProvider: 'catalog-provider',
      readExecutor: 'read-executor',
      healthContributor,
    });

    const report = await healthContributor.probe();

    expect(report.status).toBe(DbHealthStatus.healthy);
    expect(report.redactedSummary).toBe(settings.redactedSummary);
    expect(report.responseTime).toBeGreaterThanOrEqual(0);
    expect(support.catalogProvider).toBe('catalog-provider');
    expect(support.readExecutor).toBe('read-executor');
    expect(support.healthContributor).toBe(healthContributor);
  });

  it('reports unhealthy health probes when scalar execution fails', async () => {
    const settings = DbConnectionSettings.fromEnvironment();
    const provider = new FakeSessionProvider(settings);
    const executor = new FakeCommandExecutor({
      failure: new DbFailure({
        kind: DbFailureKind.timeout,
        code: 'timeout',
        message: 'Timed out',
        retryable: true,
        transient: true,
      }),
    });
    const client = new DbClient({
      settings,
      sessionProvider: provider,
      commandExecutor: executor,
      transactionRunner: new FakeTransactionRunner(),
    });
    const healthContributor = new DbHealthContributor({ client });

    const report = await healthContributor.probe();

    expect(report.status).toBe(DbHealthStatus.unhealthy);
    expect(report.details).toBe('timeout');
  });
});

class FakeSessionProvider implements DbSessionProvider<string> {
  public readonly description: DbProviderDescription;
  public readonly session: string;
  public readonly ownedByPackage: boolean;
  public readonly acquireFailure?: DbFailure;
  public readonly releaseFailure?: DbFailure;
  public readonly closeFailure?: DbFailure;

  public acquireCount = 0;
  public releaseCount = 0;
  public closeCount = 0;

  public constructor(
    settings: DbConnectionSettings,
    options: {
      session?: string;
      ownedByPackage?: boolean;
      acquireFailure?: DbFailure;
      releaseFailure?: DbFailure;
      closeFailure?: DbFailure;
    } = {},
  ) {
    this.session = options.session ?? 'session-1';
    this.ownedByPackage = options.ownedByPackage ?? true;
    this.acquireFailure = options.acquireFailure;
    this.releaseFailure = options.releaseFailure;
    this.closeFailure = options.closeFailure;
    this.description = new DbProviderDescription({
      engineId: settings.engineId,
      database: settings.database,
      redactedSummary: settings.redactedSummary,
      ownsResources: this.ownedByPackage,
    });
  }

  public async acquire(): Promise<DbResult<DbSessionLease<string>>> {
    this.acquireCount += 1;
    if (this.acquireFailure !== undefined) {
      return DbResult.failure(this.acquireFailure);
    }

    return DbResult.success(
      new DbSessionLease({
        session: this.session,
        ownedByPackage: this.ownedByPackage,
        releaser: async () => {
          this.releaseCount += 1;
          if (this.releaseFailure !== undefined) {
            return DbResult.failure(this.releaseFailure);
          }
          return DbResult.success<void>(undefined);
        },
      }),
    );
  }

  public async close(): Promise<DbResult<void>> {
    this.closeCount += 1;
    if (this.closeFailure !== undefined) {
      return DbResult.failure(this.closeFailure);
    }
    return DbResult.success<void>(undefined);
  }

  public describe(): DbProviderDescription {
    return this.description;
  }
}

class FakeCommandExecutor implements DbCommandExecutor<string> {
  public readonly rowSet: DbRowSet;
  public readonly executionSummary: DbExecutionSummary;
  public readonly scalarValue?: unknown;
  public readonly failure?: DbFailure;

  public lastSession?: string;
  public lastCommand?: DbCommand;

  public constructor(options: {
    rowSet?: DbRowSet;
    executionSummary?: DbExecutionSummary;
    scalarValue?: unknown;
    failure?: DbFailure;
  } = {}) {
    this.rowSet =
      options.rowSet ??
      new DbRowSet({
        rows: [],
        metadata: new DbExecutionMetadata({ duration: 0 }),
      });
    this.executionSummary =
      options.executionSummary ??
      new DbExecutionSummary({
        affectedCount: 0,
        metadata: new DbExecutionMetadata({ duration: 0 }),
      });
    this.scalarValue = options.scalarValue;
    this.failure = options.failure;
  }

  public async query(session: string, command: DbCommand): Promise<DbResult<DbRowSet>> {
    this.lastSession = session;
    this.lastCommand = command;
    if (this.failure !== undefined) {
      return DbResult.failure(this.failure);
    }
    return DbResult.success(this.rowSet);
  }

  public async execute(
    session: string,
    command: DbCommand,
  ): Promise<DbResult<DbExecutionSummary>> {
    this.lastSession = session;
    this.lastCommand = command;
    if (this.failure !== undefined) {
      return DbResult.failure(this.failure);
    }
    return DbResult.success(this.executionSummary);
  }

  public async scalar<T>(session: string, command: DbCommand): Promise<DbResult<DbScalar<T>>> {
    this.lastSession = session;
    this.lastCommand = command;
    if (this.failure !== undefined) {
      return DbResult.failure(this.failure);
    }
    return DbResult.success(
      new DbScalar<T>({
        value: this.scalarValue as T,
        metadata: new DbExecutionMetadata({
          duration: 0,
          commandLabel: command.label,
        }),
      }),
    );
  }
}

class FakeTransactionRunner implements DbTransactionRunner<string> {
  public commitCount = 0;
  public rollbackCount = 0;

  public async run<T>(
    context: DbTransactionContext<string>,
    body: (context: DbTransactionContext<string>) => Promise<DbResult<T>>,
  ): Promise<DbResult<T>> {
    const result = await body(context);
    if (result.isSuccess) {
      this.commitCount += 1;
    } else {
      this.rollbackCount += 1;
    }
    return result;
  }
}

class UserStatsRepository extends DbRepository<string> {
  public async totalUsers(): Promise<DbResult<number>> {
    const result = await this.scalar<number>(
      new DbCommand({
        kind: DbCommandKind.scalar,
        text: 'select count(*) from users',
        label: 'users.count',
      }),
    );
    return result.map((value) => value.value);
  }
}