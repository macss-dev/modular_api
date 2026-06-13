from __future__ import annotations

from dataclasses import dataclass

import pytest

from modular_api_postgres import (
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
    DbParameter,
    DbParameterDirection,
    DbProcedureOutcome,
    DbProviderDescription,
    DbRepository,
    DbRepositoryContext,
    DbResult,
    DbRowSet,
    DbScalar,
    DbSessionLease,
    DbTransactionContext,
)


def test_connection_settings_normalizes_environment_defaults_and_redacts_secrets() -> None:
    settings = DbConnectionSettings.from_environment(
        {
            "MODULAR_API_POSTGRES_HOST": "db.local",
            "MODULAR_API_POSTGRES_PASSWORD": "super-secret",
        }
    )

    assert settings.engine_id == "postgres"
    assert settings.host == "db.local"
    assert settings.port == 5432
    assert settings.database == "modular_api_graphql_v1"
    assert settings.username == "postgres"
    assert settings.password == "super-secret"
    assert settings.ssl_mode == "disable"
    assert "db.local:5432" in settings.redacted_summary
    assert "postgres@" in settings.redacted_summary
    assert "sslmode=disable" in settings.redacted_summary
    assert "super-secret" not in settings.redacted_summary


def test_db_result_supports_map_flat_map_map_failure_and_get_or_throw() -> None:
    success = DbResult.success(21)
    failure = DbResult.from_failure(
        DbFailure(
            kind=DbFailureKind.TIMEOUT,
            code="timeout",
            message="Timed out",
            retryable=True,
            transient=True,
        )
    )

    assert success.map(lambda value: value * 2).value == 42
    assert success.flat_map(lambda value: DbResult.success(value + 1)).value == 22

    mapped_failure = failure.map_failure(
        lambda current: DbFailure(
            kind=current.kind,
            code="wrapped_timeout",
            message=current.message,
            retryable=current.retryable,
            transient=current.transient,
        )
    )

    assert mapped_failure.failure.code == "wrapped_timeout"
    assert success.get_or_throw() == 21
    with pytest.raises(RuntimeError):
        failure.get_or_throw()


def test_client_delegates_query_calls_and_releases_package_owned_leases() -> None:
    settings = DbConnectionSettings.from_environment()
    provider = _FakeSessionProvider(settings, session="db-session")
    executor = _FakeCommandExecutor(
        row_set=DbRowSet(
            rows=[{"id": 1}],
            metadata=DbExecutionMetadata(
                duration=3,
                command_label="users.list",
                row_count=1,
            ),
        )
    )
    client = DbClient(
        settings=settings,
        session_provider=provider,
        command_executor=executor,
        transaction_runner=_FakeTransactionRunner(),
    )

    result = client.query(
        DbCommand(
            kind=DbCommandKind.QUERY,
            text="select id from users",
            label="users.list",
        )
    )

    assert result.is_success is True
    assert result.value.rows == [{"id": 1}]
    assert result.value.metadata.row_count == 1
    assert provider.acquire_count == 1
    assert provider.release_count == 1
    assert executor.last_session == "db-session"
    assert executor.last_command.label == "users.list"


def test_client_returns_a_failure_when_session_acquisition_fails() -> None:
    settings = DbConnectionSettings.from_environment()
    provider = _FakeSessionProvider(
        settings,
        acquire_failure=DbFailure(
            kind=DbFailureKind.CONNECTIVITY,
            code="connect_failed",
            message="Could not connect",
            retryable=True,
            transient=True,
        ),
    )
    client = DbClient(
        settings=settings,
        session_provider=provider,
        command_executor=_FakeCommandExecutor(),
        transaction_runner=_FakeTransactionRunner(),
    )

    result = client.query(DbCommand(kind=DbCommandKind.QUERY, text="select 1"))

    assert result.is_failure is True
    assert result.failure.code == "connect_failed"


def test_client_returns_a_failure_when_releasing_a_package_owned_lease_fails() -> None:
    settings = DbConnectionSettings.from_environment()
    provider = _FakeSessionProvider(
        settings,
        release_failure=DbFailure(
            kind=DbFailureKind.UNKNOWN,
            code="release_failed",
            message="Release failed",
            retryable=False,
            transient=False,
        ),
    )
    client = DbClient(
        settings=settings,
        session_provider=provider,
        command_executor=_FakeCommandExecutor(),
        transaction_runner=_FakeTransactionRunner(),
    )

    result = client.query(DbCommand(kind=DbCommandKind.QUERY, text="select 1"))

    assert result.is_failure is True
    assert result.failure.code == "release_failed"


def test_client_does_not_release_application_owned_leases() -> None:
    settings = DbConnectionSettings.from_environment()
    provider = _FakeSessionProvider(settings, owned_by_package=False)
    executor = _FakeCommandExecutor(
        execution_summary=DbExecutionSummary(
            affected_count=1,
            metadata=DbExecutionMetadata(
                duration=2,
                command_label="users.touch",
                affected_count=1,
            ),
        )
    )
    client = DbClient(
        settings=settings,
        session_provider=provider,
        command_executor=executor,
        transaction_runner=_FakeTransactionRunner(),
    )

    result = client.execute(
        DbCommand(
            kind=DbCommandKind.EXECUTE,
            text="update users set touched = true",
            label="users.touch",
        )
    )

    assert result.is_success is True
    assert result.value.affected_count == 1
    assert provider.release_count == 0


def test_client_commits_successful_transactions_and_rolls_back_failed_ones() -> None:
    settings = DbConnectionSettings.from_environment()
    provider = _FakeSessionProvider(settings)
    executor = _FakeCommandExecutor(scalar_value=7)
    runner = _FakeTransactionRunner()
    client = DbClient(
        settings=settings,
        session_provider=provider,
        command_executor=executor,
        transaction_runner=runner,
    )

    success = client.transaction(
        lambda transaction: transaction.scalar(
            DbCommand(
                kind=DbCommandKind.SCALAR,
                text="select count(*) from users",
                label="users.count",
            )
        ).map(lambda value: value.value)
    )
    failure = client.transaction(
        lambda _transaction: DbResult.from_failure(
            DbFailure(
                kind=DbFailureKind.CONFLICT,
                code="duplicate_key",
                message="Duplicate key",
                retryable=False,
                transient=False,
            )
        )
    )

    assert success.is_success is True
    assert success.value == 7
    assert failure.is_failure is True
    assert failure.failure.code == "duplicate_key"
    assert runner.commit_count == 1
    assert runner.rollback_count == 1
    assert provider.release_count == 2


def test_client_describes_its_provider_and_closes_cleanly() -> None:
    settings = DbConnectionSettings.from_environment()
    provider = _FakeSessionProvider(settings)
    client = DbClient(
        settings=settings,
        session_provider=provider,
        command_executor=_FakeCommandExecutor(),
        transaction_runner=_FakeTransactionRunner(),
    )

    assert client.describe().engine_id == "postgres"
    assert client.describe().database == settings.database

    closed = client.close()

    assert closed.is_success is True
    assert provider.close_count == 1


def test_client_propagates_provider_close_failures() -> None:
    settings = DbConnectionSettings.from_environment()
    provider = _FakeSessionProvider(
        settings,
        close_failure=DbFailure(
            kind=DbFailureKind.UNKNOWN,
            code="close_failed",
            message="Close failed",
            retryable=False,
            transient=False,
        ),
    )
    client = DbClient(
        settings=settings,
        session_provider=provider,
        command_executor=_FakeCommandExecutor(),
        transaction_runner=_FakeTransactionRunner(),
    )

    closed = client.close()

    assert closed.is_failure is True
    assert closed.failure.code == "close_failed"


def test_repository_helpers_stay_thin_over_the_shared_context() -> None:
    settings = DbConnectionSettings.from_environment()
    provider = _FakeSessionProvider(settings)
    executor = _FakeCommandExecutor(scalar_value=9)
    context = DbRepositoryContext(
        settings=settings,
        session_provider=provider,
        command_executor=executor,
        transaction_runner=_FakeTransactionRunner(),
    )
    repository = _UserStatsRepository(context)

    result = repository.total_users()

    assert result.is_success is True
    assert result.value == 9
    assert executor.last_command.label == "users.count"


def test_health_probe_reports_healthy_and_graphql_support_bundles_dependencies() -> None:
    settings = DbConnectionSettings.from_environment()
    provider = _FakeSessionProvider(settings)
    executor = _FakeCommandExecutor(scalar_value=1)
    client = DbClient(
        settings=settings,
        session_provider=provider,
        command_executor=executor,
        transaction_runner=_FakeTransactionRunner(),
    )
    health_contributor = DbHealthContributor(client=client)
    support = DbGraphqlSupport(
        catalog_provider="catalog-provider",
        read_executor="read-executor",
        health_contributor=health_contributor,
    )

    report = health_contributor.probe()

    assert report.status is DbHealthStatus.HEALTHY
    assert report.redacted_summary == settings.redacted_summary
    assert report.response_time >= 0
    assert support.catalog_provider == "catalog-provider"
    assert support.read_executor == "read-executor"
    assert support.health_contributor is health_contributor


def test_health_probe_reports_unhealthy_when_scalar_execution_fails() -> None:
    settings = DbConnectionSettings.from_environment()
    provider = _FakeSessionProvider(settings)
    executor = _FakeCommandExecutor(
        failure=DbFailure(
            kind=DbFailureKind.TIMEOUT,
            code="timeout",
            message="Timed out",
            retryable=True,
            transient=True,
        )
    )
    client = DbClient(
        settings=settings,
        session_provider=provider,
        command_executor=executor,
        transaction_runner=_FakeTransactionRunner(),
    )
    health_contributor = DbHealthContributor(client=client)

    report = health_contributor.probe()

    assert report.status is DbHealthStatus.UNHEALTHY
    assert report.details == "timeout"


@dataclass(slots=True)
class _FakeSessionProvider:
    settings: DbConnectionSettings
    session: str = "session-1"
    owned_by_package: bool = True
    acquire_failure: DbFailure | None = None
    release_failure: DbFailure | None = None
    close_failure: DbFailure | None = None
    acquire_count: int = 0
    release_count: int = 0
    close_count: int = 0

    def acquire(self) -> DbResult[DbSessionLease[str]]:
        self.acquire_count += 1
        if self.acquire_failure is not None:
            return DbResult.from_failure(self.acquire_failure)

        return DbResult.success(
            DbSessionLease(
                session=self.session,
                owned_by_package=self.owned_by_package,
                releaser=self._release,
            )
        )

    def close(self) -> DbResult[None]:
        self.close_count += 1
        if self.close_failure is not None:
            return DbResult.from_failure(self.close_failure)
        return DbResult.success(None)

    def describe(self) -> DbProviderDescription:
        return DbProviderDescription(
            engine_id=self.settings.engine_id,
            database=self.settings.database,
            redacted_summary=self.settings.redacted_summary,
            owns_resources=self.owned_by_package,
        )

    def _release(self) -> DbResult[None]:
        self.release_count += 1
        if self.release_failure is not None:
            return DbResult.from_failure(self.release_failure)
        return DbResult.success(None)


@dataclass(slots=True)
class _FakeCommandExecutor:
    row_set: DbRowSet = DbRowSet(
        rows=[],
        metadata=DbExecutionMetadata(duration=0),
    )
    execution_summary: DbExecutionSummary = DbExecutionSummary(
        affected_count=0,
        metadata=DbExecutionMetadata(duration=0),
    )
    scalar_value: object | None = None
    failure: DbFailure | None = None
    last_session: str | None = None
    last_command: DbCommand | None = None

    def query(self, session: str, command: DbCommand) -> DbResult[DbRowSet]:
        self.last_session = session
        self.last_command = command
        if self.failure is not None:
            return DbResult.from_failure(self.failure)
        return DbResult.success(self.row_set)

    def execute(self, session: str, command: DbCommand) -> DbResult[DbExecutionSummary]:
        self.last_session = session
        self.last_command = command
        if self.failure is not None:
            return DbResult.from_failure(self.failure)
        return DbResult.success(self.execution_summary)

    def scalar(self, session: str, command: DbCommand) -> DbResult[DbScalar[object]]:
        self.last_session = session
        self.last_command = command
        if self.failure is not None:
            return DbResult.from_failure(self.failure)
        return DbResult.success(
            DbScalar(
                value=self.scalar_value,
                metadata=DbExecutionMetadata(
                    duration=0,
                    command_label=command.label,
                ),
            )
        )


@dataclass(slots=True)
class _FakeTransactionRunner:
    commit_count: int = 0
    rollback_count: int = 0

    def run(
        self,
        context: DbTransactionContext[str],
        body: callable,
    ) -> DbResult[object]:
        result = body(context)
        if result.is_success:
            self.commit_count += 1
        else:
            self.rollback_count += 1
        return result


class _UserStatsRepository(DbRepository[str]):
    def total_users(self) -> DbResult[int]:
        result = self.scalar(
            DbCommand(
                kind=DbCommandKind.SCALAR,
                text="select count(*) from users",
                label="users.count",
            )
        )
        return result.map(lambda value: int(value.value))


# --- 0.6.0: typed parameters and stored-procedure support ---


def test_db_parameter_input_captures_name_value_and_optional_type_hint() -> None:
    plain = DbParameter.input("id", 42)
    assert plain.name == "id"
    assert plain.value == 42
    assert plain.direction is DbParameterDirection.INPUT
    assert plain.type_hint is None

    hinted = DbParameter.input("payload", b"\x01\x02\x03", "bytea")
    assert hinted.direction is DbParameterDirection.INPUT
    assert hinted.type_hint == "bytea"


def test_db_parameter_output_carries_no_input_value_and_defaults_direction() -> None:
    out = DbParameter.output("total", "integer")
    assert out.name == "total"
    assert out.value is None
    assert out.direction is DbParameterDirection.OUTPUT
    assert out.type_hint == "integer"


def test_db_parameter_input_output_marks_bidirectional_parameters() -> None:
    io = DbParameter.input_output("counter", 1, "integer")
    assert io.direction is DbParameterDirection.INPUT_OUTPUT
    assert io.value == 1


def test_db_parameter_defaults_direction_to_input_when_constructed_directly() -> None:
    param = DbParameter(name="name", value="foto.jpg")
    assert param.direction is DbParameterDirection.INPUT


def test_db_parameter_flows_through_db_command_parameters_unchanged() -> None:
    command = DbCommand(
        kind=DbCommandKind.PROCEDURE,
        text="fn_eliminar_foto",
        parameters=(DbParameter.input("nombre", "foto.jpg"), "positional-still-allowed"),
    )
    assert len(command.parameters) == 2
    assert isinstance(command.parameters[0], DbParameter)
    assert command.parameters[0].name == "nombre"
    assert command.parameters[1] == "positional-still-allowed"


def test_db_command_kind_exposes_procedure() -> None:
    assert DbCommandKind.PROCEDURE.value == "procedure"


def test_db_procedure_outcome_carries_return_value_and_output_parameters() -> None:
    outcome = DbProcedureOutcome(return_value=0, output_parameters={"total": 5})
    assert outcome.return_value == 0
    assert outcome.output_parameters == {"total": 5}


def test_db_procedure_outcome_allows_both_fields_to_be_absent() -> None:
    empty = DbProcedureOutcome()
    assert empty.return_value is None
    assert empty.output_parameters is None


def test_db_procedure_outcome_attaches_optionally_to_db_row_set() -> None:
    without_outcome = DbRowSet(
        rows=[{"id": 1}],
        metadata=DbExecutionMetadata(duration=1),
    )
    assert without_outcome.procedure is None

    with_outcome = DbRowSet(
        rows=[{"id": 1}],
        metadata=DbExecutionMetadata(duration=1),
        procedure=DbProcedureOutcome(return_value=0),
    )
    assert with_outcome.procedure is not None
    assert with_outcome.procedure.return_value == 0


def test_db_procedure_outcome_attaches_optionally_to_db_execution_summary() -> None:
    without_outcome = DbExecutionSummary(
        affected_count=1,
        metadata=DbExecutionMetadata(duration=1),
    )
    assert without_outcome.procedure is None

    with_outcome = DbExecutionSummary(
        affected_count=1,
        metadata=DbExecutionMetadata(duration=1),
        procedure=DbProcedureOutcome(output_parameters={"id": 99}),
    )
    assert with_outcome.procedure is not None
    assert with_outcome.procedure.output_parameters == {"id": 99}