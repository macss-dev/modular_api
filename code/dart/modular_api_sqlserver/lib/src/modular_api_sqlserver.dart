import 'dart:io';

enum DbCommandKind { query, execute, batch, scalar, procedure }

enum DbParameterDirection { input, output, inputOutput }

enum DbFailureKind {
  connectivity,
  timeout,
  authentication,
  authorization,
  constraint,
  conflict,
  notFound,
  serialization,
  cancelled,
  unknown,
}

enum DbHealthStatus { healthy, unhealthy }

final class DbConnectionSettings {
  const DbConnectionSettings({
    required this.host,
    required this.port,
    required this.database,
    required this.username,
    required this.password,
    required this.driver,
    this.options = const {},
  });

  factory DbConnectionSettings.fromEnvironment({
    Map<String, String>? environment,
  }) {
    final env = environment ?? Platform.environment;
    final parsedPort = int.tryParse(env['MODULAR_API_SQLSERVER_PORT'] ?? '');

    return DbConnectionSettings(
      host: env['MODULAR_API_SQLSERVER_HOST'] ?? '127.0.0.1',
      port: parsedPort ?? 14333,
      database: env['MODULAR_API_SQLSERVER_DATABASE'] ??
          'modular_api_graphql_v1',
      username: env['MODULAR_API_SQLSERVER_USERNAME'] ?? 'sa',
      password: env['MODULAR_API_SQLSERVER_PASSWORD'] ??
          'ModularApi_dev_StrongPass1',
      driver: env['MODULAR_API_SQLSERVER_DRIVER'] ??
          'ODBC Driver 17 for SQL Server',
    );
  }

  final String host;
  final int port;
  final String database;
  final String username;
  final String password;
  final String driver;
  final Map<String, Object?> options;

  String get engineId => 'sqlserver';

  String get redactedSummary {
    return '$engineId://$username@$host:$port/$database?driver=$driver';
  }
}

final class DbCommand {
  const DbCommand({
    required this.kind,
    required this.text,
    this.parameters = const [],
    this.label,
  });

  final DbCommandKind kind;
  final String text;
  final List<Object?> parameters;
  final String? label;
}

final class DbParameter {
  const DbParameter({
    required this.name,
    this.value,
    this.direction = DbParameterDirection.input,
    this.typeHint,
  });

  factory DbParameter.input(String name, Object? value, [String? typeHint]) =>
      DbParameter(name: name, value: value, typeHint: typeHint);

  factory DbParameter.output(String name, [String? typeHint]) => DbParameter(
        name: name,
        direction: DbParameterDirection.output,
        typeHint: typeHint,
      );

  factory DbParameter.inputOutput(String name, Object? value, [String? typeHint]) =>
      DbParameter(
        name: name,
        value: value,
        direction: DbParameterDirection.inputOutput,
        typeHint: typeHint,
      );

  final String name;
  final Object? value;
  final DbParameterDirection direction;
  final String? typeHint;
}

final class DbProcedureOutcome {
  const DbProcedureOutcome({this.returnValue, this.outputParameters});

  final Object? returnValue;
  final Map<String, Object?>? outputParameters;
}

final class DbExecutionMetadata {
  const DbExecutionMetadata({
    required this.duration,
    this.commandLabel,
    this.rowCount,
    this.affectedCount,
  });

  final Duration duration;
  final String? commandLabel;
  final int? rowCount;
  final int? affectedCount;
}

final class DbRowSet {
  const DbRowSet({
    required this.rows,
    required this.metadata,
    this.procedure,
  });

  final List<Map<String, Object?>> rows;
  final DbExecutionMetadata metadata;
  final DbProcedureOutcome? procedure;
}

final class DbExecutionSummary {
  const DbExecutionSummary({
    required this.affectedCount,
    required this.metadata,
    this.procedure,
  });

  final int affectedCount;
  final DbExecutionMetadata metadata;
  final DbProcedureOutcome? procedure;
}

final class DbScalar<T> {
  const DbScalar({required this.value, required this.metadata});

  final T value;
  final DbExecutionMetadata metadata;
}

final class DbFailure {
  const DbFailure({
    required this.kind,
    required this.code,
    required this.message,
    required this.retryable,
    required this.transient,
    this.details,
    this.causeSummary,
  });

  final DbFailureKind kind;
  final String code;
  final String message;
  final bool retryable;
  final bool transient;
  final Object? details;
  final String? causeSummary;
}

final class DbResult<T> {
  const DbResult._({
    required this.isSuccess,
    T? value,
    DbFailure? failure,
  }) : _value = value,
       _failure = failure;

  factory DbResult.success(T value) {
    return DbResult._(isSuccess: true, value: value);
  }

  factory DbResult.failure(DbFailure failure) {
    return DbResult._(isSuccess: false, failure: failure);
  }

  final bool isSuccess;
  final T? _value;
  final DbFailure? _failure;

  bool get isFailure => !isSuccess;

  T get value {
    if (isFailure) {
      throw StateError('DbResult does not contain a success value.');
    }
    return _value as T;
  }

  DbFailure get failure {
    if (isSuccess) {
      throw StateError('DbResult does not contain a failure value.');
    }
    return _failure!;
  }

  DbResult<R> map<R>(R Function(T value) transform) {
    if (isFailure) {
      return DbResult<R>.failure(failure);
    }
    return DbResult<R>.success(transform(value));
  }

  DbResult<R> flatMap<R>(DbResult<R> Function(T value) transform) {
    if (isFailure) {
      return DbResult<R>.failure(failure);
    }
    return transform(value);
  }

  DbResult<T> mapFailure(DbFailure Function(DbFailure failure) transform) {
    if (isSuccess) {
      return DbResult<T>.success(value);
    }
    return DbResult<T>.failure(transform(failure));
  }

  T getOrThrow([String? message]) {
    if (isFailure) {
      throw StateError(message ?? failure.message);
    }
    return value;
  }
}

final class DbProviderDescription {
  const DbProviderDescription({
    required this.engineId,
    required this.database,
    required this.redactedSummary,
    required this.ownsResources,
  });

  final String engineId;
  final String database;
  final String redactedSummary;
  final bool ownsResources;
}

typedef DbLeaseRelease = Future<DbResult<void>> Function();

final class DbSessionLease<S> {
  const DbSessionLease({
    required this.session,
    required this.ownedByPackage,
    required DbLeaseRelease releaser,
  }) : _releaser = releaser;

  final S session;
  final bool ownedByPackage;
  final DbLeaseRelease _releaser;

  Future<DbResult<void>> release() async {
    if (!ownedByPackage) {
      return DbResult<void>.success(null);
    }
    return _releaser();
  }
}

abstract interface class DbSessionProvider<S> {
  Future<DbResult<DbSessionLease<S>>> acquire();

  Future<DbResult<void>> close();

  DbProviderDescription describe();
}

abstract interface class DbCommandExecutor<S> {
  Future<DbResult<DbRowSet>> query(S session, DbCommand command);

  Future<DbResult<DbExecutionSummary>> execute(S session, DbCommand command);

  Future<DbResult<DbScalar<T>>> scalar<T>(S session, DbCommand command);
}

final class DbTransactionContext<S> {
  const DbTransactionContext({
    required this.settings,
    required this.session,
    required this.commandExecutor,
  });

  final DbConnectionSettings settings;
  final S session;
  final DbCommandExecutor<S> commandExecutor;

  Future<DbResult<DbRowSet>> query(DbCommand command) {
    return commandExecutor.query(session, command);
  }

  Future<DbResult<DbExecutionSummary>> execute(DbCommand command) {
    return commandExecutor.execute(session, command);
  }

  Future<DbResult<DbScalar<T>>> scalar<T>(DbCommand command) {
    return commandExecutor.scalar<T>(session, command);
  }
}

abstract interface class DbTransactionRunner<S> {
  Future<DbResult<T>> run<T>(
    DbTransactionContext<S> context,
    Future<DbResult<T>> Function(DbTransactionContext<S> context) body,
  );
}

final class DbRepositoryContext<S> {
  const DbRepositoryContext({
    required this.settings,
    required this.sessionProvider,
    required this.commandExecutor,
    required this.transactionRunner,
  });

  final DbConnectionSettings settings;
  final DbSessionProvider<S> sessionProvider;
  final DbCommandExecutor<S> commandExecutor;
  final DbTransactionRunner<S> transactionRunner;
}

abstract base class DbRepository<S> {
  const DbRepository(this.context);

  final DbRepositoryContext<S> context;

  Future<DbResult<DbRowSet>> query(DbCommand command) {
    return _withLease<S, DbRowSet>(context.sessionProvider, (lease) {
      return context.commandExecutor.query(lease.session, command);
    });
  }

  Future<DbResult<DbExecutionSummary>> execute(DbCommand command) {
    return _withLease<S, DbExecutionSummary>(context.sessionProvider, (lease) {
      return context.commandExecutor.execute(lease.session, command);
    });
  }

  Future<DbResult<DbScalar<T>>> scalar<T>(DbCommand command) {
    return _withLease<S, DbScalar<T>>(context.sessionProvider, (lease) {
      return context.commandExecutor.scalar<T>(lease.session, command);
    });
  }

  Future<DbResult<T>> transaction<T>(
    Future<DbResult<T>> Function(DbTransactionContext<S> context) body,
  ) {
    final client = DbClient<S>(
      settings: context.settings,
      sessionProvider: context.sessionProvider,
      commandExecutor: context.commandExecutor,
      transactionRunner: context.transactionRunner,
    );
    return client.transaction(body);
  }
}

final class DbClient<S> {
  const DbClient({
    required this.settings,
    required this.sessionProvider,
    required this.commandExecutor,
    required this.transactionRunner,
  });

  final DbConnectionSettings settings;
  final DbSessionProvider<S> sessionProvider;
  final DbCommandExecutor<S> commandExecutor;
  final DbTransactionRunner<S> transactionRunner;

  Future<DbResult<DbRowSet>> query(DbCommand command) {
    return _withLease<S, DbRowSet>(sessionProvider, (lease) {
      return commandExecutor.query(lease.session, command);
    });
  }

  Future<DbResult<DbExecutionSummary>> execute(DbCommand command) {
    return _withLease<S, DbExecutionSummary>(sessionProvider, (lease) {
      return commandExecutor.execute(lease.session, command);
    });
  }

  Future<DbResult<DbScalar<T>>> scalar<T>(DbCommand command) {
    return _withLease<S, DbScalar<T>>(sessionProvider, (lease) {
      return commandExecutor.scalar<T>(lease.session, command);
    });
  }

  Future<DbResult<T>> transaction<T>(
    Future<DbResult<T>> Function(DbTransactionContext<S> context) body,
  ) async {
    final leaseResult = await sessionProvider.acquire();
    if (leaseResult.isFailure) {
      return DbResult<T>.failure(leaseResult.failure);
    }

    final lease = leaseResult.value;
    final transactionContext = DbTransactionContext<S>(
      settings: settings,
      session: lease.session,
      commandExecutor: commandExecutor,
    );
    final result = await transactionRunner.run<T>(transactionContext, body);
    final releaseResult = await lease.release();

    if (result.isFailure) {
      return DbResult<T>.failure(result.failure);
    }
    if (releaseResult.isFailure) {
      return DbResult<T>.failure(releaseResult.failure);
    }

    return result;
  }

  DbRepositoryContext<S> repositoryContext() {
    return DbRepositoryContext<S>(
      settings: settings,
      sessionProvider: sessionProvider,
      commandExecutor: commandExecutor,
      transactionRunner: transactionRunner,
    );
  }

  Future<DbResult<void>> close() {
    return sessionProvider.close();
  }

  DbProviderDescription describe() {
    return sessionProvider.describe();
  }
}

final class DbHealthReport {
  const DbHealthReport({
    required this.status,
    required this.responseTime,
    required this.redactedSummary,
    this.details,
  });

  final DbHealthStatus status;
  final Duration responseTime;
  final String redactedSummary;
  final String? details;
}

final class DbHealthContributor<S> {
  const DbHealthContributor({
    required this.client,
    this.probeCommand = const DbCommand(
      kind: DbCommandKind.scalar,
      text: 'SELECT 1',
      label: 'db.health',
    ),
  });

  final DbClient<S> client;
  final DbCommand probeCommand;

  Future<DbHealthReport> probe() async {
    final stopwatch = Stopwatch()..start();
    final result = await client.scalar<Object?>(probeCommand);
    stopwatch.stop();

    if (result.isSuccess) {
      return DbHealthReport(
        status: DbHealthStatus.healthy,
        responseTime: stopwatch.elapsed,
        redactedSummary: client.describe().redactedSummary,
      );
    }

    return DbHealthReport(
      status: DbHealthStatus.unhealthy,
      responseTime: stopwatch.elapsed,
      redactedSummary: client.describe().redactedSummary,
      details: result.failure.code,
    );
  }
}

final class DbGraphqlSupport<S> {
  const DbGraphqlSupport({
    required this.catalogProvider,
    required this.readExecutor,
    required this.healthContributor,
    this.sourceDigestFactory,
    this.artifactLoader,
    this.capabilityRegistration,
  });

  final Object catalogProvider;
  final Object readExecutor;
  final DbHealthContributor<S> healthContributor;
  final Object? sourceDigestFactory;
  final Object? artifactLoader;
  final Object? capabilityRegistration;
}

Future<DbResult<T>> _withLease<S, T>(
  DbSessionProvider<S> sessionProvider,
  Future<DbResult<T>> Function(DbSessionLease<S> lease) operation,
) async {
  final leaseResult = await sessionProvider.acquire();
  if (leaseResult.isFailure) {
    return DbResult<T>.failure(leaseResult.failure);
  }

  final lease = leaseResult.value;
  final operationResult = await operation(lease);
  final releaseResult = await lease.release();

  if (operationResult.isFailure) {
    return DbResult<T>.failure(operationResult.failure);
  }
  if (releaseResult.isFailure) {
    return DbResult<T>.failure(releaseResult.failure);
  }

  return operationResult;
}