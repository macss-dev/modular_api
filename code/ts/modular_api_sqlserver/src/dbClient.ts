export enum DbCommandKind {
  query = 'query',
  execute = 'execute',
  batch = 'batch',
  scalar = 'scalar',
}

export enum DbFailureKind {
  connectivity = 'connectivity',
  timeout = 'timeout',
  authentication = 'authentication',
  authorization = 'authorization',
  constraint = 'constraint',
  conflict = 'conflict',
  notFound = 'not_found',
  serialization = 'serialization',
  cancelled = 'cancelled',
  unknown = 'unknown',
}

export enum DbHealthStatus {
  healthy = 'healthy',
  unhealthy = 'unhealthy',
}

export class DbConnectionSettings {
  public readonly host: string;
  public readonly port: number;
  public readonly database: string;
  public readonly username: string;
  public readonly password: string;
  public readonly driver: string;
  public readonly options: Record<string, unknown>;

  public constructor(options: {
    host: string;
    port: number;
    database: string;
    username: string;
    password: string;
    driver: string;
    options?: Record<string, unknown>;
  }) {
    this.host = options.host;
    this.port = options.port;
    this.database = options.database;
    this.username = options.username;
    this.password = options.password;
    this.driver = options.driver;
    this.options = { ...(options.options ?? {}) };
  }

  public static fromEnvironment(
    environment: Record<string, string | undefined> = process.env,
  ): DbConnectionSettings {
    const parsedPort = Number.parseInt(environment.MODULAR_API_SQLSERVER_PORT ?? '', 10);

    return new DbConnectionSettings({
      host: environment.MODULAR_API_SQLSERVER_HOST ?? '127.0.0.1',
      port: Number.isNaN(parsedPort) ? 14333 : parsedPort,
      database: environment.MODULAR_API_SQLSERVER_DATABASE ?? 'modular_api_graphql_v1',
      username: environment.MODULAR_API_SQLSERVER_USERNAME ?? 'sa',
      password: environment.MODULAR_API_SQLSERVER_PASSWORD ?? 'ModularApi_dev_StrongPass1',
      driver: environment.MODULAR_API_SQLSERVER_DRIVER ?? 'ODBC Driver 17 for SQL Server',
    });
  }

  public get engineId(): string {
    return 'sqlserver';
  }

  public get redactedSummary(): string {
    return `${this.engineId}://${this.username}@${this.host}:${this.port}/${this.database}?driver=${this.driver}`;
  }
}

export class DbCommand {
  public readonly kind: DbCommandKind;
  public readonly text: string;
  public readonly parameters: unknown[];
  public readonly label?: string;

  public constructor(options: {
    kind: DbCommandKind;
    text: string;
    parameters?: unknown[];
    label?: string;
  }) {
    this.kind = options.kind;
    this.text = options.text;
    this.parameters = [...(options.parameters ?? [])];
    this.label = options.label;
  }
}

export class DbExecutionMetadata {
  public readonly duration: number;
  public readonly commandLabel?: string;
  public readonly rowCount?: number;
  public readonly affectedCount?: number;

  public constructor(options: {
    duration: number;
    commandLabel?: string;
    rowCount?: number;
    affectedCount?: number;
  }) {
    this.duration = options.duration;
    this.commandLabel = options.commandLabel;
    this.rowCount = options.rowCount;
    this.affectedCount = options.affectedCount;
  }
}

export class DbRowSet {
  public readonly rows: Array<Record<string, unknown>>;
  public readonly metadata: DbExecutionMetadata;

  public constructor(options: { rows: Array<Record<string, unknown>>; metadata: DbExecutionMetadata }) {
    this.rows = [...options.rows];
    this.metadata = options.metadata;
  }
}

export class DbExecutionSummary {
  public readonly affectedCount: number;
  public readonly metadata: DbExecutionMetadata;

  public constructor(options: { affectedCount: number; metadata: DbExecutionMetadata }) {
    this.affectedCount = options.affectedCount;
    this.metadata = options.metadata;
  }
}

export class DbScalar<T> {
  public readonly value: T;
  public readonly metadata: DbExecutionMetadata;

  public constructor(options: { value: T; metadata: DbExecutionMetadata }) {
    this.value = options.value;
    this.metadata = options.metadata;
  }
}

export class DbFailure {
  public readonly kind: DbFailureKind;
  public readonly code: string;
  public readonly message: string;
  public readonly retryable: boolean;
  public readonly transient: boolean;
  public readonly details?: unknown;
  public readonly causeSummary?: string;

  public constructor(options: {
    kind: DbFailureKind;
    code: string;
    message: string;
    retryable: boolean;
    transient: boolean;
    details?: unknown;
    causeSummary?: string;
  }) {
    this.kind = options.kind;
    this.code = options.code;
    this.message = options.message;
    this.retryable = options.retryable;
    this.transient = options.transient;
    this.details = options.details;
    this.causeSummary = options.causeSummary;
  }
}

export class DbResult<T> {
  private readonly innerValue?: T;
  private readonly innerFailure?: DbFailure;

  private constructor(value?: T, failure?: DbFailure) {
    this.innerValue = value;
    this.innerFailure = failure;
  }

  public static success<T>(value: T): DbResult<T> {
    return new DbResult<T>(value, undefined);
  }

  public static failure<T>(failure: DbFailure): DbResult<T> {
    return new DbResult<T>(undefined, failure);
  }

  public get isSuccess(): boolean {
    return this.innerFailure === undefined;
  }

  public get isFailure(): boolean {
    return this.innerFailure !== undefined;
  }

  public get value(): T {
    if (this.innerFailure !== undefined) {
      throw new Error('DbResult does not contain a success value.');
    }
    return this.innerValue as T;
  }

  public get failure(): DbFailure {
    if (this.innerFailure === undefined) {
      throw new Error('DbResult does not contain a failure value.');
    }
    return this.innerFailure;
  }

  public map<R>(transform: (value: T) => R): DbResult<R> {
    if (this.isFailure) {
      return DbResult.failure(this.failure);
    }
    return DbResult.success(transform(this.value));
  }

  public flatMap<R>(transform: (value: T) => DbResult<R>): DbResult<R> {
    if (this.isFailure) {
      return DbResult.failure(this.failure);
    }
    return transform(this.value);
  }

  public mapFailure(transform: (failure: DbFailure) => DbFailure): DbResult<T> {
    if (this.isSuccess) {
      return DbResult.success(this.value);
    }
    return DbResult.failure(transform(this.failure));
  }

  public getOrThrow(message?: string): T {
    if (this.isFailure) {
      throw new Error(message ?? this.failure.message);
    }
    return this.value;
  }
}

export class DbProviderDescription {
  public readonly engineId: string;
  public readonly database: string;
  public readonly redactedSummary: string;
  public readonly ownsResources: boolean;

  public constructor(options: {
    engineId: string;
    database: string;
    redactedSummary: string;
    ownsResources: boolean;
  }) {
    this.engineId = options.engineId;
    this.database = options.database;
    this.redactedSummary = options.redactedSummary;
    this.ownsResources = options.ownsResources;
  }
}

export class DbSessionLease<S> {
  public readonly session: S;
  public readonly ownedByPackage: boolean;
  private readonly releaser: () => Promise<DbResult<void>>;

  public constructor(options: {
    session: S;
    ownedByPackage: boolean;
    releaser: () => Promise<DbResult<void>>;
  }) {
    this.session = options.session;
    this.ownedByPackage = options.ownedByPackage;
    this.releaser = options.releaser;
  }

  public async release(): Promise<DbResult<void>> {
    if (!this.ownedByPackage) {
      return DbResult.success<void>(undefined);
    }
    return this.releaser();
  }
}

export interface DbSessionProvider<S> {
  acquire(): Promise<DbResult<DbSessionLease<S>>>;
  close(): Promise<DbResult<void>>;
  describe(): DbProviderDescription;
}

export interface DbCommandExecutor<S> {
  query(session: S, command: DbCommand): Promise<DbResult<DbRowSet>>;
  execute(session: S, command: DbCommand): Promise<DbResult<DbExecutionSummary>>;
  scalar<T>(session: S, command: DbCommand): Promise<DbResult<DbScalar<T>>>;
}

export class DbTransactionContext<S> {
  public readonly settings: DbConnectionSettings;
  public readonly session: S;
  public readonly commandExecutor: DbCommandExecutor<S>;

  public constructor(options: {
    settings: DbConnectionSettings;
    session: S;
    commandExecutor: DbCommandExecutor<S>;
  }) {
    this.settings = options.settings;
    this.session = options.session;
    this.commandExecutor = options.commandExecutor;
  }

  public query(command: DbCommand): Promise<DbResult<DbRowSet>> {
    return this.commandExecutor.query(this.session, command);
  }

  public execute(command: DbCommand): Promise<DbResult<DbExecutionSummary>> {
    return this.commandExecutor.execute(this.session, command);
  }

  public scalar<T>(command: DbCommand): Promise<DbResult<DbScalar<T>>> {
    return this.commandExecutor.scalar<T>(this.session, command);
  }
}

export interface DbTransactionRunner<S> {
  run<T>(
    context: DbTransactionContext<S>,
    body: (context: DbTransactionContext<S>) => Promise<DbResult<T>>,
  ): Promise<DbResult<T>>;
}

export class DbRepositoryContext<S> {
  public readonly settings: DbConnectionSettings;
  public readonly sessionProvider: DbSessionProvider<S>;
  public readonly commandExecutor: DbCommandExecutor<S>;
  public readonly transactionRunner: DbTransactionRunner<S>;

  public constructor(options: {
    settings: DbConnectionSettings;
    sessionProvider: DbSessionProvider<S>;
    commandExecutor: DbCommandExecutor<S>;
    transactionRunner: DbTransactionRunner<S>;
  }) {
    this.settings = options.settings;
    this.sessionProvider = options.sessionProvider;
    this.commandExecutor = options.commandExecutor;
    this.transactionRunner = options.transactionRunner;
  }
}

export abstract class DbRepository<S> {
  public constructor(public readonly context: DbRepositoryContext<S>) {}

  public query(command: DbCommand): Promise<DbResult<DbRowSet>> {
    return withLease(this.context.sessionProvider, (lease) =>
      this.context.commandExecutor.query(lease.session, command),
    );
  }

  public execute(command: DbCommand): Promise<DbResult<DbExecutionSummary>> {
    return withLease(this.context.sessionProvider, (lease) =>
      this.context.commandExecutor.execute(lease.session, command),
    );
  }

  public scalar<T>(command: DbCommand): Promise<DbResult<DbScalar<T>>> {
    return withLease(this.context.sessionProvider, (lease) =>
      this.context.commandExecutor.scalar<T>(lease.session, command),
    );
  }

  public transaction<T>(
    body: (context: DbTransactionContext<S>) => Promise<DbResult<T>>,
  ): Promise<DbResult<T>> {
    const client = new DbClient({
      settings: this.context.settings,
      sessionProvider: this.context.sessionProvider,
      commandExecutor: this.context.commandExecutor,
      transactionRunner: this.context.transactionRunner,
    });
    return client.transaction(body);
  }
}

export class DbClient<S> {
  public readonly settings: DbConnectionSettings;
  public readonly sessionProvider: DbSessionProvider<S>;
  public readonly commandExecutor: DbCommandExecutor<S>;
  public readonly transactionRunner: DbTransactionRunner<S>;

  public constructor(options: {
    settings: DbConnectionSettings;
    sessionProvider: DbSessionProvider<S>;
    commandExecutor: DbCommandExecutor<S>;
    transactionRunner: DbTransactionRunner<S>;
  }) {
    this.settings = options.settings;
    this.sessionProvider = options.sessionProvider;
    this.commandExecutor = options.commandExecutor;
    this.transactionRunner = options.transactionRunner;
  }

  public query(command: DbCommand): Promise<DbResult<DbRowSet>> {
    return withLease(this.sessionProvider, (lease) =>
      this.commandExecutor.query(lease.session, command),
    );
  }

  public execute(command: DbCommand): Promise<DbResult<DbExecutionSummary>> {
    return withLease(this.sessionProvider, (lease) =>
      this.commandExecutor.execute(lease.session, command),
    );
  }

  public scalar<T>(command: DbCommand): Promise<DbResult<DbScalar<T>>> {
    return withLease(this.sessionProvider, (lease) =>
      this.commandExecutor.scalar<T>(lease.session, command),
    );
  }

  public async transaction<T>(
    body: (context: DbTransactionContext<S>) => Promise<DbResult<T>>,
  ): Promise<DbResult<T>> {
    const leaseResult = await this.sessionProvider.acquire();
    if (leaseResult.isFailure) {
      return DbResult.failure(leaseResult.failure);
    }

    const lease = leaseResult.value;
    const context = new DbTransactionContext({
      settings: this.settings,
      session: lease.session,
      commandExecutor: this.commandExecutor,
    });
    const result = await this.transactionRunner.run(context, body);
    const releaseResult = await lease.release();

    if (result.isFailure) {
      return DbResult.failure(result.failure);
    }
    if (releaseResult.isFailure) {
      return DbResult.failure(releaseResult.failure);
    }

    return result;
  }

  public repositoryContext(): DbRepositoryContext<S> {
    return new DbRepositoryContext({
      settings: this.settings,
      sessionProvider: this.sessionProvider,
      commandExecutor: this.commandExecutor,
      transactionRunner: this.transactionRunner,
    });
  }

  public close(): Promise<DbResult<void>> {
    return this.sessionProvider.close();
  }

  public describe(): DbProviderDescription {
    return this.sessionProvider.describe();
  }
}

export class DbHealthReport {
  public readonly status: DbHealthStatus;
  public readonly responseTime: number;
  public readonly redactedSummary: string;
  public readonly details?: string;

  public constructor(options: {
    status: DbHealthStatus;
    responseTime: number;
    redactedSummary: string;
    details?: string;
  }) {
    this.status = options.status;
    this.responseTime = options.responseTime;
    this.redactedSummary = options.redactedSummary;
    this.details = options.details;
  }
}

export class DbHealthContributor<S> {
  public readonly client: DbClient<S>;
  public readonly probeCommand: DbCommand;

  public constructor(options: {
    client: DbClient<S>;
    probeCommand?: DbCommand;
  }) {
    this.client = options.client;
    this.probeCommand =
      options.probeCommand ??
      new DbCommand({
        kind: DbCommandKind.scalar,
        text: 'SELECT 1',
        label: 'db.health',
      });
  }

  public async probe(): Promise<DbHealthReport> {
    const startedAt = Date.now();
    const result = await this.client.scalar(this.probeCommand);
    const responseTime = Date.now() - startedAt;

    if (result.isSuccess) {
      return new DbHealthReport({
        status: DbHealthStatus.healthy,
        responseTime,
        redactedSummary: this.client.describe().redactedSummary,
      });
    }

    return new DbHealthReport({
      status: DbHealthStatus.unhealthy,
      responseTime,
      redactedSummary: this.client.describe().redactedSummary,
      details: result.failure.code,
    });
  }
}

export class DbGraphqlSupport<S> {
  public readonly catalogProvider: unknown;
  public readonly readExecutor: unknown;
  public readonly healthContributor: DbHealthContributor<S>;
  public readonly sourceDigestFactory?: unknown;
  public readonly artifactLoader?: unknown;
  public readonly capabilityRegistration?: unknown;

  public constructor(options: {
    catalogProvider: unknown;
    readExecutor: unknown;
    healthContributor: DbHealthContributor<S>;
    sourceDigestFactory?: unknown;
    artifactLoader?: unknown;
    capabilityRegistration?: unknown;
  }) {
    this.catalogProvider = options.catalogProvider;
    this.readExecutor = options.readExecutor;
    this.healthContributor = options.healthContributor;
    this.sourceDigestFactory = options.sourceDigestFactory;
    this.artifactLoader = options.artifactLoader;
    this.capabilityRegistration = options.capabilityRegistration;
  }
}

async function withLease<S, T>(
  sessionProvider: DbSessionProvider<S>,
  operation: (lease: DbSessionLease<S>) => Promise<DbResult<T>>,
): Promise<DbResult<T>> {
  const leaseResult = await sessionProvider.acquire();
  if (leaseResult.isFailure) {
    return DbResult.failure(leaseResult.failure);
  }

  const lease = leaseResult.value;
  const operationResult = await operation(lease);
  const releaseResult = await lease.release();

  if (operationResult.isFailure) {
    return DbResult.failure(operationResult.failure);
  }
  if (releaseResult.isFailure) {
    return DbResult.failure(releaseResult.failure);
  }

  return operationResult;
}