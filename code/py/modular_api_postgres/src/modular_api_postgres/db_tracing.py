"""Database spans for the contracts this package ships.

**Instrumentation is a decorator over the contract, not a change to ``DbClient``.** ADR-0004 makes
this package contracts-only, and ``DbClient``, ``DbRepository`` and ``DbTransactionContext`` all
delegate to the same application-supplied ``DbCommandExecutor``. Wrapping that one collaborator
instruments every call path at once — including commands issued inside a transaction body, which
``DbClient.transaction`` routes through a freshly built ``DbTransactionContext`` carrying the same
executor.

It follows that **not wrapping is how you turn tracing off**, so the cost of not using it is zero
rather than a branch per call (gate G3).

The Dart and TypeScript counterparts are ``lib/src/db_tracing.dart`` and ``src/dbTracing.ts``.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Callable, Generic, TypeVar

from opentelemetry import trace
from opentelemetry.trace import Span, SpanKind, Status, StatusCode, Tracer

from modular_api_postgres.db_client import (
    DbClient,
    DbCommand,
    DbCommandExecutor,
    DbCommandKind,
    DbConnectionSettings,
    DbExecutionSummary,
    DbProviderDescription,
    DbResult,
    DbRowSet,
    DbScalar,
    DbSessionLease,
    DbSessionProvider,
    DbTransactionContext,
    DbTransactionRunner,
)

S = TypeVar("S")
T = TypeVar("T")


@dataclass(frozen=True, slots=True)
class DbTracingOptions:
    """How much a database span is allowed to say.

    ``include_query_text`` is **off by default** (runbook D9). SQL can carry personal or financial
    data in a literal, and a span is not a place that is reviewed for that. Parameter *values* are
    never recorded regardless of this setting: the text is a template, the parameters are the data.
    """

    include_query_text: bool = False
    instrumentation_name: str = "modular_api_postgres"


def trace_db_client(
    client: DbClient[S],
    options: DbTracingOptions | None = None,
) -> DbClient[S]:
    """Wrap ``client`` so its commands, transactions and session acquisitions produce spans.

    The wrapped client is a drop-in replacement: same settings, same ``DbProviderDescription``, so
    ``DbHealthContributor`` and GraphQL support keep working unchanged. A repository built from the
    wrapped client is instrumented too — call ``repository_context()`` on the result rather than on
    the original.
    """
    resolved = options or DbTracingOptions()
    tracer = trace.get_tracer(resolved.instrumentation_name)
    target = _DbTarget(client.settings)

    return DbClient(
        settings=client.settings,
        session_provider=_TracedSessionProvider(client.session_provider, tracer, target),
        command_executor=_TracedCommandExecutor(
            client.command_executor, tracer, target, resolved
        ),
        transaction_runner=_TracedTransactionRunner(client.transaction_runner, tracer, target),
    )


class _DbTarget:
    """The attributes that describe *where* the database is, computed once per client."""

    #: The value the semantic conventions register for Postgres.
    #:
    #: Deliberately not ``settings.engine_id``, which is ``postgres``: a backend keying its Postgres
    #: dashboards off ``db.system.name`` would not match on that.
    SYSTEM_NAME = "postgresql"

    __slots__ = ("host", "namespace", "port")

    def __init__(self, settings: DbConnectionSettings) -> None:
        self.namespace = settings.database
        self.host = settings.host
        self.port = settings.port


#: The SQL verbs an operation name may take.
#:
#: An allowlist rather than "the first word", so an unusual leading token — a comment, a driver
#: directive — is dropped instead of emitted. That keeps the attribute low-cardinality and makes it
#: impossible for a fragment of a query to arrive as an operation name.
_SQL_OPERATIONS = frozenset(
    {
        "SELECT",
        "INSERT",
        "UPDATE",
        "DELETE",
        "MERGE",
        "UPSERT",
        "CALL",
        "WITH",
        "CREATE",
        "ALTER",
        "DROP",
        "TRUNCATE",
        "GRANT",
        "REVOKE",
        "EXPLAIN",
        "ANALYZE",
        "VACUUM",
        "COPY",
        "BEGIN",
        "COMMIT",
        "ROLLBACK",
        "SET",
        "SHOW",
        "LISTEN",
        "NOTIFY",
        "REFRESH",
    }
)

_LEADING_WORD = re.compile(r"^\s*([A-Za-z_]+)")


def _operation_name(command: DbCommand) -> str | None:
    match = _LEADING_WORD.match(command.text)
    if match is None:
        return None

    candidate = match.group(1).upper()
    return candidate if candidate in _SQL_OPERATIONS else None


def _start_db_span(
    tracer: Tracer,
    *,
    target: _DbTarget,
    operation: str | None = None,
    summary: str | None = None,
    query_text: str | None = None,
    batch_size: int | None = None,
) -> Span | None:
    """Start a span for one database operation, or return ``None`` when tracing is off.

    ``None`` rather than a non-recording span: with no recording parent there is nothing to attach
    to, and a span nobody will read is cost with no benefit.
    """
    parent = trace.get_current_span()
    if not parent.is_recording():
        return None

    attributes: dict[str, object] = {
        "db.system.name": _DbTarget.SYSTEM_NAME,
        "db.namespace": target.namespace,
        "server.address": target.host,
        "server.port": target.port,
    }
    if operation is not None:
        attributes["db.operation.name"] = operation
    if summary is not None:
        attributes["db.query.summary"] = summary
    if query_text is not None:
        attributes["db.query.text"] = query_text
    if batch_size is not None:
        attributes["db.operation.batch.size"] = batch_size

    return tracer.start_span(
        # The conventions ask for ``{operation} {target}``, and prefer ``db.query.summary`` when one
        # exists. ``DbCommand.label`` is exactly that — application-supplied and stable — so it wins
        # over anything derived from the SQL. Never the SQL text itself: unbounded cardinality, and
        # possibly personal data.
        summary or f"{operation or 'QUERY'} {target.namespace}",
        kind=SpanKind.CLIENT,  # A database call leaves the process.
        attributes=attributes,
    )


def _end_db_span(
    span: Span | None,
    result: DbResult[object],
    returned_rows: int | None = None,
) -> None:
    """Record the outcome on ``span`` and end it.

    Failures arrive as a ``DbResult``, never as a raised exception, so this inspects the result. A
    decorator that only wrapped a ``try``/``except`` would report every timeout as a success.

    The failure *message* is deliberately not copied: a driver message can quote the offending row.
    The code and the kind are what diagnose the problem.
    """
    if span is None:
        return

    if result.is_failure:
        failure = result.failure
        span.set_attribute("db.response.status_code", failure.code)
        span.set_attribute("modular_api.db.failure_kind", failure.kind.value)
        span.set_status(Status(StatusCode.ERROR))
    elif returned_rows is not None:
        span.set_attribute("db.response.returned_rows", returned_rows)

    span.end()


class _TracedCommandExecutor(Generic[S]):
    __slots__ = ("_inner", "_options", "_target", "_tracer")

    def __init__(
        self,
        inner: DbCommandExecutor[S],
        tracer: Tracer,
        target: _DbTarget,
        options: DbTracingOptions,
    ) -> None:
        self._inner = inner
        self._tracer = tracer
        self._target = target
        self._options = options

    def _start(self, command: DbCommand) -> Span | None:
        return _start_db_span(
            self._tracer,
            target=self._target,
            operation=_operation_name(command),
            summary=command.label,
            query_text=command.text if self._options.include_query_text else None,
            batch_size=(
                len(command.parameters) if command.kind is DbCommandKind.BATCH else None
            ),
        )

    def query(self, session: S, command: DbCommand) -> DbResult[DbRowSet]:
        span = self._start(command)
        result = self._inner.query(session, command)
        rows = None
        if result.is_success:
            rows = result.value.metadata.row_count
            if rows is None:
                rows = len(result.value.rows)
        _end_db_span(span, result, rows)
        return result

    def execute(self, session: S, command: DbCommand) -> DbResult[DbExecutionSummary]:
        span = self._start(command)
        result = self._inner.execute(session, command)
        _end_db_span(span, result)
        return result

    def scalar(self, session: S, command: DbCommand) -> DbResult[DbScalar[object]]:
        span = self._start(command)
        result = self._inner.scalar(session, command)
        _end_db_span(span, result)
        return result


class _TracedTransactionRunner(Generic[S]):
    __slots__ = ("_inner", "_target", "_tracer")

    def __init__(
        self,
        inner: DbTransactionRunner[S],
        tracer: Tracer,
        target: _DbTarget,
    ) -> None:
        self._inner = inner
        self._tracer = tracer
        self._target = target

    def run(
        self,
        context: DbTransactionContext[S],
        body: Callable[[DbTransactionContext[S]], DbResult[T]],
    ) -> DbResult[T]:
        span = _start_db_span(self._tracer, target=self._target, operation="TRANSACTION")
        if span is None:
            return self._inner.run(context, body)

        # Made ambient so commands issued through the transaction context become its children
        # rather than siblings — the nesting is what makes a transaction readable in a waterfall.
        # ``end_on_exit=False`` because ``_end_db_span`` records the outcome first.
        with trace.use_span(span, end_on_exit=False):
            result = self._inner.run(context, body)

        _end_db_span(span, result)
        return result


class _TracedSessionProvider(Generic[S]):
    __slots__ = ("_inner", "_target", "_tracer")

    def __init__(
        self,
        inner: DbSessionProvider[S],
        tracer: Tracer,
        target: _DbTarget,
    ) -> None:
        self._inner = inner
        self._tracer = tracer
        self._target = target

    def acquire(self) -> DbResult[DbSessionLease[S]]:
        """Acquisition gets its own span (runbook D28).

        Without it, time spent waiting for a connection lands in no span at all — an unattributed
        gap that reads as nothing having happened rather than as queueing for the pool. Pool
        exhaustion is a live hypothesis for ``socia``, so this is the number that confirms or kills
        it.
        """
        span = _start_db_span(self._tracer, target=self._target, operation="CONNECT")
        result = self._inner.acquire()
        _end_db_span(span, result)
        return result

    def close(self) -> DbResult[None]:
        return self._inner.close()

    def describe(self) -> DbProviderDescription:
        return self._inner.describe()
