from __future__ import annotations

import os
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Generic, Mapping, Protocol, TypeVar, cast

S = TypeVar("S")
T = TypeVar("T")
R = TypeVar("R")
_MISSING = object()


class DbCommandKind(str, Enum):
    QUERY = "query"
    EXECUTE = "execute"
    BATCH = "batch"
    SCALAR = "scalar"
    PROCEDURE = "procedure"


class DbParameterDirection(str, Enum):
    INPUT = "input"
    OUTPUT = "output"
    INPUT_OUTPUT = "inputOutput"


class DbFailureKind(str, Enum):
    CONNECTIVITY = "connectivity"
    TIMEOUT = "timeout"
    AUTHENTICATION = "authentication"
    AUTHORIZATION = "authorization"
    CONSTRAINT = "constraint"
    CONFLICT = "conflict"
    NOT_FOUND = "not_found"
    SERIALIZATION = "serialization"
    CANCELLED = "cancelled"
    UNKNOWN = "unknown"


class DbHealthStatus(str, Enum):
    HEALTHY = "healthy"
    UNHEALTHY = "unhealthy"


@dataclass(frozen=True, slots=True)
class DbConnectionSettings:
    host: str
    port: int
    database: str
    username: str
    password: str
    driver: str
    options: Mapping[str, object] = field(default_factory=dict)

    @classmethod
    def from_environment(
        cls,
        environment: Mapping[str, str] | None = None,
    ) -> DbConnectionSettings:
        values = os.environ if environment is None else environment
        raw_port = values.get("MODULAR_API_SQLSERVER_PORT", "")

        try:
            port = int(raw_port)
        except ValueError:
            port = 14333

        return cls(
            host=values.get("MODULAR_API_SQLSERVER_HOST", "127.0.0.1"),
            port=port,
            database=values.get("MODULAR_API_SQLSERVER_DATABASE", "modular_api_graphql_v1"),
            username=values.get("MODULAR_API_SQLSERVER_USERNAME", "sa"),
            password=values.get("MODULAR_API_SQLSERVER_PASSWORD", "ModularApi_dev_StrongPass1"),
            driver=values.get(
                "MODULAR_API_SQLSERVER_DRIVER",
                "ODBC Driver 17 for SQL Server",
            ),
        )

    @property
    def engine_id(self) -> str:
        return "sqlserver"

    @property
    def redacted_summary(self) -> str:
        return (
            f"{self.engine_id}://{self.username}@{self.host}:{self.port}/"
            f"{self.database}?driver={self.driver}"
        )


@dataclass(frozen=True, slots=True)
class DbParameter:
    name: str
    value: object | None = None
    direction: DbParameterDirection = DbParameterDirection.INPUT
    type_hint: str | None = None

    @classmethod
    def input(cls, name: str, value: object | None, type_hint: str | None = None) -> DbParameter:
        return cls(name=name, value=value, direction=DbParameterDirection.INPUT, type_hint=type_hint)

    @classmethod
    def output(cls, name: str, type_hint: str | None = None) -> DbParameter:
        return cls(name=name, direction=DbParameterDirection.OUTPUT, type_hint=type_hint)

    @classmethod
    def input_output(
        cls, name: str, value: object | None, type_hint: str | None = None
    ) -> DbParameter:
        return cls(
            name=name,
            value=value,
            direction=DbParameterDirection.INPUT_OUTPUT,
            type_hint=type_hint,
        )


@dataclass(frozen=True, slots=True)
class DbProcedureOutcome:
    return_value: object | None = None
    output_parameters: Mapping[str, object] | None = None


@dataclass(frozen=True, slots=True)
class DbCommand:
    kind: DbCommandKind
    text: str
    parameters: tuple[object, ...] = field(default_factory=tuple)
    label: str | None = None


@dataclass(frozen=True, slots=True)
class DbExecutionMetadata:
    duration: int
    command_label: str | None = None
    row_count: int | None = None
    affected_count: int | None = None


@dataclass(frozen=True, slots=True)
class DbRowSet:
    rows: list[Mapping[str, object]]
    metadata: DbExecutionMetadata
    procedure: DbProcedureOutcome | None = None


@dataclass(frozen=True, slots=True)
class DbExecutionSummary:
    affected_count: int
    metadata: DbExecutionMetadata
    procedure: DbProcedureOutcome | None = None


@dataclass(frozen=True, slots=True)
class DbScalar(Generic[T]):
    value: T
    metadata: DbExecutionMetadata


@dataclass(frozen=True, slots=True)
class DbFailure:
    kind: DbFailureKind
    code: str
    message: str
    retryable: bool
    transient: bool
    details: object | None = None
    cause_summary: str | None = None


class DbResult(Generic[T]):
    def __init__(self, value: object = _MISSING, failure: DbFailure | None = None) -> None:
        self._value = value
        self._failure = failure

    @classmethod
    def success(cls, value: T) -> DbResult[T]:
        return cls(value=value)

    @classmethod
    def from_failure(cls, failure: DbFailure) -> DbResult[T]:
        return cls(failure=failure)

    @property
    def is_success(self) -> bool:
        return self._failure is None

    @property
    def is_failure(self) -> bool:
        return self._failure is not None

    @property
    def value(self) -> T:
        if self._failure is not None or self._value is _MISSING:
            raise RuntimeError("DbResult does not contain a success value.")
        return cast(T, self._value)

    @property
    def failure(self) -> DbFailure:
        if self._failure is None:
            raise RuntimeError("DbResult does not contain a failure value.")
        return self._failure

    def map(self, transform: Callable[[T], R]) -> DbResult[R]:
        if self.is_failure:
            return DbResult.from_failure(self.failure)
        return DbResult.success(transform(self.value))

    def flat_map(self, transform: Callable[[T], DbResult[R]]) -> DbResult[R]:
        if self.is_failure:
            return DbResult.from_failure(self.failure)
        return transform(self.value)

    def map_failure(self, transform: Callable[[DbFailure], DbFailure]) -> DbResult[T]:
        if self.is_success:
            return DbResult.success(self.value)
        return DbResult.from_failure(transform(self.failure))

    def get_or_throw(self, message: str | None = None) -> T:
        if self.is_failure:
            raise RuntimeError(message or self.failure.message)
        return self.value


@dataclass(frozen=True, slots=True)
class DbProviderDescription:
    engine_id: str
    database: str
    redacted_summary: str
    owns_resources: bool


class DbSessionLease(Generic[S]):
    def __init__(
        self,
        *,
        session: S,
        owned_by_package: bool,
        releaser: Callable[[], DbResult[None]],
    ) -> None:
        self.session = session
        self.owned_by_package = owned_by_package
        self._releaser = releaser

    def release(self) -> DbResult[None]:
        if not self.owned_by_package:
            return DbResult.success(None)
        return self._releaser()


class DbSessionProvider(Protocol[S]):
    def acquire(self) -> DbResult[DbSessionLease[S]]: ...

    def close(self) -> DbResult[None]: ...

    def describe(self) -> DbProviderDescription: ...


class DbCommandExecutor(Protocol[S]):
    def query(self, session: S, command: DbCommand) -> DbResult[DbRowSet]: ...

    def execute(self, session: S, command: DbCommand) -> DbResult[DbExecutionSummary]: ...

    def scalar(self, session: S, command: DbCommand) -> DbResult[DbScalar[object]]: ...


@dataclass(frozen=True, slots=True)
class DbTransactionContext(Generic[S]):
    settings: DbConnectionSettings
    session: S
    command_executor: DbCommandExecutor[S]

    def query(self, command: DbCommand) -> DbResult[DbRowSet]:
        return self.command_executor.query(self.session, command)

    def execute(self, command: DbCommand) -> DbResult[DbExecutionSummary]:
        return self.command_executor.execute(self.session, command)

    def scalar(self, command: DbCommand) -> DbResult[DbScalar[T]]:
        return cast(DbResult[DbScalar[T]], self.command_executor.scalar(self.session, command))


class DbTransactionRunner(Protocol[S]):
    def run(
        self,
        context: DbTransactionContext[S],
        body: Callable[[DbTransactionContext[S]], DbResult[T]],
    ) -> DbResult[T]: ...


@dataclass(frozen=True, slots=True)
class DbRepositoryContext(Generic[S]):
    settings: DbConnectionSettings
    session_provider: DbSessionProvider[S]
    command_executor: DbCommandExecutor[S]
    transaction_runner: DbTransactionRunner[S]


class DbRepository(Generic[S]):
    def __init__(self, context: DbRepositoryContext[S]) -> None:
        self.context = context

    def query(self, command: DbCommand) -> DbResult[DbRowSet]:
        return _with_lease(
            self.context.session_provider,
            lambda lease: self.context.command_executor.query(lease.session, command),
        )

    def execute(self, command: DbCommand) -> DbResult[DbExecutionSummary]:
        return _with_lease(
            self.context.session_provider,
            lambda lease: self.context.command_executor.execute(lease.session, command),
        )

    def scalar(self, command: DbCommand) -> DbResult[DbScalar[T]]:
        return cast(
            DbResult[DbScalar[T]],
            _with_lease(
                self.context.session_provider,
                lambda lease: self.context.command_executor.scalar(lease.session, command),
            ),
        )

    def transaction(self, body: Callable[[DbTransactionContext[S]], DbResult[T]]) -> DbResult[T]:
        client = DbClient(
            settings=self.context.settings,
            session_provider=self.context.session_provider,
            command_executor=self.context.command_executor,
            transaction_runner=self.context.transaction_runner,
        )
        return client.transaction(body)


class DbClient(Generic[S]):
    def __init__(
        self,
        *,
        settings: DbConnectionSettings,
        session_provider: DbSessionProvider[S],
        command_executor: DbCommandExecutor[S],
        transaction_runner: DbTransactionRunner[S],
    ) -> None:
        self.settings = settings
        self.session_provider = session_provider
        self.command_executor = command_executor
        self.transaction_runner = transaction_runner

    def query(self, command: DbCommand) -> DbResult[DbRowSet]:
        return _with_lease(
            self.session_provider,
            lambda lease: self.command_executor.query(lease.session, command),
        )

    def execute(self, command: DbCommand) -> DbResult[DbExecutionSummary]:
        return _with_lease(
            self.session_provider,
            lambda lease: self.command_executor.execute(lease.session, command),
        )

    def scalar(self, command: DbCommand) -> DbResult[DbScalar[T]]:
        return cast(
            DbResult[DbScalar[T]],
            _with_lease(
                self.session_provider,
                lambda lease: self.command_executor.scalar(lease.session, command),
            ),
        )

    def transaction(self, body: Callable[[DbTransactionContext[S]], DbResult[T]]) -> DbResult[T]:
        lease_result = self.session_provider.acquire()
        if lease_result.is_failure:
            return DbResult.from_failure(lease_result.failure)

        lease = lease_result.value
        context = DbTransactionContext(
            settings=self.settings,
            session=lease.session,
            command_executor=self.command_executor,
        )
        result = self.transaction_runner.run(context, body)
        release_result = lease.release()

        if result.is_failure:
            return DbResult.from_failure(result.failure)
        if release_result.is_failure:
            return DbResult.from_failure(release_result.failure)
        return result

    def repository_context(self) -> DbRepositoryContext[S]:
        return DbRepositoryContext(
            settings=self.settings,
            session_provider=self.session_provider,
            command_executor=self.command_executor,
            transaction_runner=self.transaction_runner,
        )

    def close(self) -> DbResult[None]:
        return self.session_provider.close()

    def describe(self) -> DbProviderDescription:
        return self.session_provider.describe()


@dataclass(frozen=True, slots=True)
class DbHealthReport:
    status: DbHealthStatus
    response_time: int
    redacted_summary: str
    details: str | None = None


class DbHealthContributor(Generic[S]):
    def __init__(self, *, client: DbClient[S], probe_command: DbCommand | None = None) -> None:
        self.client = client
        self.probe_command = probe_command or DbCommand(
            kind=DbCommandKind.SCALAR,
            text="SELECT 1",
            label="db.health",
        )

    def probe(self) -> DbHealthReport:
        started_at = time.monotonic()
        result = self.client.scalar(self.probe_command)
        response_time = int((time.monotonic() - started_at) * 1000)

        if result.is_success:
            return DbHealthReport(
                status=DbHealthStatus.HEALTHY,
                response_time=response_time,
                redacted_summary=self.client.describe().redacted_summary,
            )

        return DbHealthReport(
            status=DbHealthStatus.UNHEALTHY,
            response_time=response_time,
            redacted_summary=self.client.describe().redacted_summary,
            details=result.failure.code,
        )


@dataclass(frozen=True, slots=True)
class DbGraphqlSupport(Generic[S]):
    catalog_provider: object
    read_executor: object
    health_contributor: DbHealthContributor[S]
    source_digest_factory: object | None = None
    artifact_loader: object | None = None
    capability_registration: object | None = None


def _with_lease(
    session_provider: DbSessionProvider[S],
    operation: Callable[[DbSessionLease[S]], DbResult[T]],
) -> DbResult[T]:
    lease_result = session_provider.acquire()
    if lease_result.is_failure:
        return DbResult.from_failure(lease_result.failure)

    lease = lease_result.value
    operation_result = operation(lease)
    release_result = lease.release()

    if operation_result.is_failure:
        return DbResult.from_failure(operation_result.failure)
    if release_result.is_failure:
        return DbResult.from_failure(release_result.failure)
    return operation_result