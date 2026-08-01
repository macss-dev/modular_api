"""Python mirror of ``test/tracing_test.dart``.

**Instrumentation is a decorator, not a change to ``DbClient``.** ADR-0004 makes this package
contracts-only: ``DbClient``, ``DbRepository`` and ``DbTransactionContext`` all delegate to an
application-supplied ``DbCommandExecutor``. Wrapping that one collaborator instruments all three
call paths at once, including commands issued inside a transaction body, and leaves every existing
line of the package untouched.

**The SQL text is off by default** (D9). The attribute is ``db.query.text`` — ``db.statement`` is
deprecated, a correction this stage made after checking the semantic conventions package itself
rather than trusting what the runbook had written down.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Callable, Generic, TypeVar

import pytest
from opentelemetry import trace
from opentelemetry.sdk.trace import ReadableSpan, TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from opentelemetry.trace import SpanKind, StatusCode

from modular_api_postgres.db_client import (
    DbClient,
    DbCommand,
    DbCommandKind,
    DbConnectionSettings,
    DbExecutionMetadata,
    DbExecutionSummary,
    DbFailure,
    DbFailureKind,
    DbProviderDescription,
    DbResult,
    DbRowSet,
    DbScalar,
    DbSessionLease,
    DbTransactionContext,
)
from modular_api_postgres.db_tracing import DbTracingOptions, trace_db_client

_exporter = InMemorySpanExporter()
_provider = TracerProvider()
_provider.add_span_processor(SimpleSpanProcessor(_exporter))
trace.set_tracer_provider(_provider)

_tracer = _provider.get_tracer("test-host")

S = TypeVar("S")

_SETTINGS = DbConnectionSettings.from_environment(
    environment={
        "MODULAR_API_POSTGRES_HOST": "db.internal",
        "MODULAR_API_POSTGRES_DATABASE": "socia",
    }
)

_SELECT_USERS = DbCommand(
    kind=DbCommandKind.QUERY,
    text="SELECT id, dni FROM cuenta WHERE dni = @dni",
    parameters=("12345678",),
    label="SELECT cuenta",
)


@pytest.fixture(autouse=True)
def _reset() -> Iterator[None]:
    _exporter.clear()
    yield


def _span_named(name: str) -> ReadableSpan | None:
    for span in _exporter.get_finished_spans():
        if span.name == name:
            return span
    return None


def _span_names() -> list[str]:
    return [span.name for span in _exporter.get_finished_spans()]


def _client(
    *,
    failure: DbFailure | None = None,
    acquire_failure: DbFailure | None = None,
    options: DbTracingOptions | None = None,
) -> DbClient[str]:
    return trace_db_client(
        DbClient(
            settings=_SETTINGS,
            session_provider=_FakeSessionProvider(acquire_failure),
            command_executor=_FakeCommandExecutor(failure),
            transaction_runner=_FakeTransactionRunner(),
        ),
        options,
    )


def _within_server_span(body: Callable[[], object]) -> None:
    """Database spans are children of whatever the request made active.

    Exactly as the client span in ``macss-modular-api-rest-client`` is. There is no separate wiring
    for it.
    """
    server_span = _tracer.start_span("POST /api/cuenta", kind=SpanKind.SERVER)
    with trace.use_span(server_span, end_on_exit=True):
        body()


# --- command spans ----------------------------------------------------------


def test_a_span_wraps_command_execution_named_by_the_command_label() -> None:
    # The semantic conventions ask for a low-cardinality name and offer `db.query.summary` for it.
    # `DbCommand.label` is exactly that — application-supplied and stable — so it is preferred over
    # anything parsed out of the SQL.
    _within_server_span(lambda: _client().query(_SELECT_USERS))

    assert "SELECT cuenta" in _span_names()


def test_an_unlabelled_command_falls_back_to_operation_and_namespace() -> None:
    # Never the SQL text: that is unbounded cardinality and possibly personal data.
    _within_server_span(
        lambda: _client().query(DbCommand(kind=DbCommandKind.QUERY, text="SELECT 1"))
    )

    assert "SELECT socia" in _span_names()


def test_the_span_is_kind_client_and_a_child_of_the_active_server_span() -> None:
    # kind=client, not internal: a database call leaves the process.
    _within_server_span(lambda: _client().query(_SELECT_USERS))

    server = _span_named("POST /api/cuenta")
    command = _span_named("SELECT cuenta")

    assert command is not None and server is not None
    assert command.kind is SpanKind.CLIENT
    assert command.context.trace_id == server.context.trace_id


def test_records_the_stable_database_attributes() -> None:
    _within_server_span(lambda: _client().query(_SELECT_USERS))

    span = _span_named("SELECT cuenta")
    assert span is not None
    attributes = span.attributes or {}

    assert attributes["db.system.name"] == "postgresql"
    assert attributes["db.namespace"] == "socia"
    assert attributes["db.operation.name"] == "SELECT"
    assert attributes["db.query.summary"] == "SELECT cuenta"
    assert attributes["server.address"] == "db.internal"
    assert attributes["server.port"] == 5432


def test_emits_none_of_the_deprecated_database_attributes() -> None:
    # Emitting them would fail silently against a current backend, which is worse than failing
    # loudly: it looks like the instrumentation not working.
    _within_server_span(lambda: _client().query(_SELECT_USERS))

    span = _span_named("SELECT cuenta")
    assert span is not None
    attributes = span.attributes or {}

    for deprecated in ("db.system", "db.name", "db.operation", "db.statement"):
        assert deprecated not in attributes


def test_db_system_name_is_the_registered_value_not_our_engine_id() -> None:
    # Our `engine_id` is `postgres`; the conventions register `postgresql`. A backend that keys its
    # Postgres dashboards off this attribute would not match on `postgres`.
    _within_server_span(lambda: _client().query(_SELECT_USERS))

    span = _span_named("SELECT cuenta")
    assert span is not None
    assert (span.attributes or {})["db.system.name"] == "postgresql"


def test_the_row_count_is_recorded() -> None:
    _within_server_span(lambda: _client().query(_SELECT_USERS))

    span = _span_named("SELECT cuenta")
    assert span is not None
    assert (span.attributes or {})["db.response.returned_rows"] == 1


def test_execute_and_scalar_are_instrumented_too_with_their_own_operations() -> None:
    def body() -> None:
        client = _client()
        client.execute(
            DbCommand(
                kind=DbCommandKind.EXECUTE,
                text="UPDATE cuenta SET saldo = 0",
                label="UPDATE cuenta",
            )
        )
        client.scalar(
            DbCommand(
                kind=DbCommandKind.SCALAR,
                text="SELECT count(*) FROM cuenta",
                label="COUNT cuenta",
            )
        )

    _within_server_span(body)

    updated = _span_named("UPDATE cuenta")
    counted = _span_named("COUNT cuenta")

    assert updated is not None and counted is not None
    assert (updated.attributes or {})["db.operation.name"] == "UPDATE"
    assert (counted.attributes or {})["db.operation.name"] == "SELECT"


def test_an_unrecognised_leading_token_yields_no_operation_name() -> None:
    # The operation name comes from an allowlist of SQL verbs. Anything else — a leading comment, a
    # driver-specific directive — is dropped rather than emitted, which keeps the attribute
    # low-cardinality and cannot leak a fragment of the query.
    _within_server_span(
        lambda: _client().query(
            DbCommand(
                kind=DbCommandKind.QUERY,
                text="/* tenant 4471 */ SELECT 1",
                label="odd",
            )
        )
    )

    span = _span_named("odd")
    assert span is not None
    assert "db.operation.name" not in (span.attributes or {})


# --- the SQL text (D9) ------------------------------------------------------


def test_db_query_text_is_absent_by_default() -> None:
    _within_server_span(lambda: _client().query(_SELECT_USERS))

    span = _span_named("SELECT cuenta")
    assert span is not None
    assert "db.query.text" not in (span.attributes or {})


def test_db_query_text_is_present_when_explicitly_opted_in() -> None:
    _within_server_span(
        lambda: _client(options=DbTracingOptions(include_query_text=True)).query(_SELECT_USERS)
    )

    span = _span_named("SELECT cuenta")
    assert span is not None
    assert (span.attributes or {})["db.query.text"] == (
        "SELECT id, dni FROM cuenta WHERE dni = @dni"
    )


def test_parameter_values_are_never_recorded_even_when_the_text_is() -> None:
    # The text is a template; the parameters are the data. Opting into one must not opt into the
    # other, or D9's protection would be pointless for a parameterised query.
    _within_server_span(
        lambda: _client(options=DbTracingOptions(include_query_text=True)).query(_SELECT_USERS)
    )

    span = _span_named("SELECT cuenta")
    assert span is not None

    for value in (span.attributes or {}).values():
        assert "12345678" not in str(value)


# --- failures ---------------------------------------------------------------

_TIMEOUT = DbFailure(
    kind=DbFailureKind.TIMEOUT,
    code="57014",
    message="canceling statement due to statement timeout",
    retryable=True,
    transient=True,
)


def test_a_failed_command_sets_error_status_and_records_the_failure_kind() -> None:
    # Failures arrive as a `DbResult`, not as a raised exception, so the span has to inspect the
    # result. A decorator that only wrapped a try/except would report every timeout as OK.
    _within_server_span(lambda: _client(failure=_TIMEOUT).query(_SELECT_USERS))

    span = _span_named("SELECT cuenta")
    assert span is not None
    attributes = span.attributes or {}

    assert span.status.status_code is StatusCode.ERROR
    assert attributes["db.response.status_code"] == "57014"
    assert attributes["modular_api.db.failure_kind"] == "timeout"


def test_the_failure_message_is_not_copied_into_the_span() -> None:
    # A driver message can quote the offending row. The code and kind are enough to diagnose.
    _within_server_span(
        lambda: _client(
            failure=DbFailure(
                kind=DbFailureKind.CONSTRAINT,
                code="23505",
                message="duplicate key value violates unique constraint: dni=12345678",
                retryable=False,
                transient=False,
            )
        ).query(_SELECT_USERS)
    )

    span = _span_named("SELECT cuenta")
    assert span is not None

    for value in (span.attributes or {}).values():
        assert "12345678" not in str(value)


def test_the_span_is_still_ended_when_the_command_fails() -> None:
    _within_server_span(lambda: _client(failure=_TIMEOUT).query(_SELECT_USERS))

    span = _span_named("SELECT cuenta")
    assert span is not None
    assert span.end_time is not None


# --- transactions -----------------------------------------------------------


def _transaction_body(context: DbTransactionContext[str]) -> DbResult[int]:
    context.query(_SELECT_USERS)
    return DbResult.success(1)


def test_a_transaction_span_wraps_the_body() -> None:
    _within_server_span(lambda: _client().transaction(_transaction_body))

    assert "TRANSACTION socia" in _span_names()


def test_commands_inside_the_body_nest_under_the_transaction_span() -> None:
    # This is what the decorator buys us: `DbTransactionContext` is built inside
    # `DbClient.transaction` from the same executor, so wrapping the executor once covers commands
    # issued through the transaction context as well.
    _within_server_span(lambda: _client().transaction(_transaction_body))

    transaction = _span_named("TRANSACTION socia")
    command = _span_named("SELECT cuenta")

    assert transaction is not None and command is not None
    assert command.parent is not None
    assert command.parent.span_id == transaction.context.span_id


def test_a_failed_transaction_sets_error_status_on_the_transaction_span() -> None:
    def failing(_context: DbTransactionContext[str]) -> DbResult[int]:
        return DbResult.from_failure(
            DbFailure(
                kind=DbFailureKind.SERIALIZATION,
                code="40001",
                message="could not serialize access",
                retryable=True,
                transient=True,
            )
        )

    _within_server_span(lambda: _client().transaction(failing))

    transaction = _span_named("TRANSACTION socia")
    assert transaction is not None
    assert transaction.status.status_code is StatusCode.ERROR
    assert (transaction.attributes or {})["modular_api.db.failure_kind"] == "serialization"


# --- session acquisition (D28) ----------------------------------------------


def test_acquiring_a_session_produces_its_own_span() -> None:
    # The number that separates "the query was slow" from "we queued for a connection". Without it,
    # pool wait time lands in no span at all — an unattributed gap that reads as nothing having
    # happened.
    _within_server_span(lambda: _client().query(_SELECT_USERS))

    assert "CONNECT socia" in _span_names()


def test_the_acquisition_span_precedes_the_command_span() -> None:
    _within_server_span(lambda: _client().query(_SELECT_USERS))

    connect = _span_named("CONNECT socia")
    command = _span_named("SELECT cuenta")

    assert connect is not None and command is not None
    assert connect.start_time <= command.start_time


def test_a_failed_acquisition_is_an_error_and_no_command_span_follows() -> None:
    _within_server_span(
        lambda: _client(
            acquire_failure=DbFailure(
                kind=DbFailureKind.CONNECTIVITY,
                code="pool_exhausted",
                message="no connection available",
                retryable=True,
                transient=True,
            )
        ).query(_SELECT_USERS)
    )

    connect = _span_named("CONNECT socia")
    assert connect is not None
    assert connect.status.status_code is StatusCode.ERROR
    assert "SELECT cuenta" not in _span_names()


# --- without tracing configured (gate G3) -----------------------------------


def test_an_unwrapped_client_produces_no_spans() -> None:
    # Instrumentation is opt-in by construction: not wrapping is how you turn it off, so the cost of
    # not using it is exactly zero rather than a branch per call.
    _within_server_span(
        lambda: DbClient(
            settings=_SETTINGS,
            session_provider=_FakeSessionProvider(),
            command_executor=_FakeCommandExecutor(),
            transaction_runner=_FakeTransactionRunner(),
        ).query(_SELECT_USERS)
    )

    assert "SELECT cuenta" not in _span_names()


def test_a_wrapped_client_with_no_active_span_emits_nothing() -> None:
    # No recording parent means the request was not sampled, or tracing is off entirely.
    _client().query(_SELECT_USERS)

    assert _exporter.get_finished_spans() == ()


def test_the_call_still_succeeds_with_no_active_span() -> None:
    result = _client().query(_SELECT_USERS)

    assert result.is_success


def test_wrapping_preserves_the_provider_description_and_settings() -> None:
    # The wrapped client must be a drop-in replacement, including for the health contributor and
    # GraphQL support that read `describe()`.
    client = _client()

    assert client.describe().engine_id == "postgres"
    assert client.settings.database == "socia"


# --- fakes ------------------------------------------------------------------

_METADATA = DbExecutionMetadata(duration=2, row_count=1, affected_count=1)


class _FakeSessionProvider:
    def __init__(self, failure: DbFailure | None = None) -> None:
        self._failure = failure

    def acquire(self) -> DbResult[DbSessionLease[str]]:
        if self._failure is not None:
            return DbResult.from_failure(self._failure)
        return DbResult.success(
            DbSessionLease(
                session="session",
                owned_by_package=True,
                releaser=lambda: DbResult.success(None),
            )
        )

    def close(self) -> DbResult[None]:
        return DbResult.success(None)

    def describe(self) -> DbProviderDescription:
        return DbProviderDescription(
            engine_id=_SETTINGS.engine_id,
            database=_SETTINGS.database,
            redacted_summary=_SETTINGS.redacted_summary,
            owns_resources=True,
        )


class _FakeCommandExecutor:
    def __init__(self, failure: DbFailure | None = None) -> None:
        self._failure = failure

    def query(self, _session: str, _command: DbCommand) -> DbResult[DbRowSet]:
        if self._failure is not None:
            return DbResult.from_failure(self._failure)
        return DbResult.success(DbRowSet(rows=[{"id": 1}], metadata=_METADATA))

    def execute(self, _session: str, _command: DbCommand) -> DbResult[DbExecutionSummary]:
        if self._failure is not None:
            return DbResult.from_failure(self._failure)
        return DbResult.success(DbExecutionSummary(affected_count=1, metadata=_METADATA))

    def scalar(self, _session: str, _command: DbCommand) -> DbResult[DbScalar[object]]:
        if self._failure is not None:
            return DbResult.from_failure(self._failure)
        return DbResult.success(DbScalar(value=1, metadata=_METADATA))


class _FakeTransactionRunner(Generic[S]):
    def run(
        self,
        context: DbTransactionContext[S],
        body: Callable[[DbTransactionContext[S]], DbResult[object]],
    ) -> DbResult[object]:
        return body(context)
