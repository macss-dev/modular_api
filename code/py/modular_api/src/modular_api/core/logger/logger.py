"""Structured JSON logger — RFC 5424 levels, request-scoped, zero dependencies.

Each log entry is a single JSON line with fixed fields:
``ts``, ``level``, ``severity``, ``msg``, ``service``, ``trace_id``.
Optional ``fields`` dict carries structured data from the caller.
"""

from __future__ import annotations

import json
import sys
import time
from enum import IntEnum
from typing import Callable, Protocol


class LogLevel(IntEnum):
    """RFC 5424 log levels in descending severity order.

    Filtering rule: if configured ``log_level = X``, only messages with
    ``value <= X`` are emitted.
    """

    emergency = 0  # system unusable
    alert = 1      # immediate action required
    critical = 2   # critical condition
    error = 3      # operation error, 5xx
    warning = 4    # abnormal condition, 4xx
    notice = 5     # normal but significant
    info = 6       # normal flow, 2xx/3xx
    debug = 7      # detailed diagnostics


class ModularLogger(Protocol):
    """Public logger interface exposed to UseCases.

    Each method corresponds to an RFC 5424 severity level.
    """

    @property
    def trace_id(self) -> str: ...
    def emergency(self, msg: str, *, fields: dict[str, object] | None = None) -> None: ...
    def alert(self, msg: str, *, fields: dict[str, object] | None = None) -> None: ...
    def critical(self, msg: str, *, fields: dict[str, object] | None = None) -> None: ...
    def error(self, msg: str, *, fields: dict[str, object] | None = None) -> None: ...
    def warning(self, msg: str, *, fields: dict[str, object] | None = None) -> None: ...
    def notice(self, msg: str, *, fields: dict[str, object] | None = None) -> None: ...
    def info(self, msg: str, *, fields: dict[str, object] | None = None) -> None: ...
    def debug(self, msg: str, *, fields: dict[str, object] | None = None) -> None: ...


# Signature for the output sink — default writes to stdout.
WriteFn = Callable[[str], object]


def _default_write(line: str) -> None:
    sys.stdout.write(line + "\n")


#: Builds platform-specific correlation fields from the ids the framework resolved.
#:
#: The framework emits open formats and nothing vendor-specific (roadmap invariant 7), so
#: a field like Google's ``logging.googleapis.com/trace`` — which needs a project id the
#: framework has no business knowing — is produced by the application.
TraceFieldFormatter = Callable[[str, str | None], dict[str, object]]


class RequestScopedLogger:
    """Per-request logger carrying ``trace_id`` with ``log_level`` filtering.

    Created by the logging middleware for each HTTP request and injected
    into the UseCase via the ``logger`` property.

    Pass a custom ``write_fn`` for testability (capture output without I/O).
    """

    def __init__(
        self,
        *,
        trace_id: str,
        log_level: LogLevel,
        service_name: str,
        write_fn: WriteFn = _default_write,
        span_id: str | None = None,
        request_id: str | None = None,
        trace_field_formatter: TraceFieldFormatter | None = None,
    ) -> None:
        self._trace_id = trace_id
        self._log_level = log_level
        self._service_name = service_name
        self._write_fn = write_fn
        # Known at construction because the tracing middleware is outermost (runbook D12
        # as reversed): the span already exists when logging_middleware creates this
        # logger, so nothing needs mutating afterwards.
        self._span_id = span_id
        # The caller's X-Request-ID, preserved beside the trace id rather than promoted
        # into it (runbook D6).
        self._request_id = request_id
        self._trace_field_formatter = trace_field_formatter

    @property
    def trace_id(self) -> str:
        return self._trace_id

    # ── Public API (8 RFC 5424 levels) ──────────────────────────────

    def emergency(self, msg: str, *, fields: dict[str, object] | None = None) -> None:
        self._log(LogLevel.emergency, msg, fields=fields)

    def alert(self, msg: str, *, fields: dict[str, object] | None = None) -> None:
        self._log(LogLevel.alert, msg, fields=fields)

    def critical(self, msg: str, *, fields: dict[str, object] | None = None) -> None:
        self._log(LogLevel.critical, msg, fields=fields)

    def error(self, msg: str, *, fields: dict[str, object] | None = None) -> None:
        self._log(LogLevel.error, msg, fields=fields)

    def warning(self, msg: str, *, fields: dict[str, object] | None = None) -> None:
        self._log(LogLevel.warning, msg, fields=fields)

    def notice(self, msg: str, *, fields: dict[str, object] | None = None) -> None:
        self._log(LogLevel.notice, msg, fields=fields)

    def info(self, msg: str, *, fields: dict[str, object] | None = None) -> None:
        self._log(LogLevel.info, msg, fields=fields)

    def debug(self, msg: str, *, fields: dict[str, object] | None = None) -> None:
        self._log(LogLevel.debug, msg, fields=fields)

    # ── Framework-internal: request/response logging ────────────────

    def log_request(self, *, method: str, route: str) -> None:
        """Emit a 'request received' log at info level."""
        self._log(LogLevel.info, "request received", extra={"method": method, "route": route})

    def log_response(
        self,
        *,
        method: str,
        route: str,
        status_code: int,
        duration_ms: float,
        extra: dict[str, object] | None = None,
    ) -> None:
        """Emit a 'request completed' log at the level determined by status_code."""
        self._log(
            _level_for_status(status_code),
            "request completed",
            extra={
                "method": method,
                "route": route,
                "status": status_code,
                "duration_ms": duration_ms,
                **(extra or {}),
            },
        )

    def log_unhandled_exception(self, *, route: str, duration_ms: float) -> None:
        """Emit an 'unhandled exception' log at error level. No stack trace by design."""
        self._log(LogLevel.error, "unhandled exception", extra={"route": route, "status": 500})

    # ── Internal ────────────────────────────────────────────────────

    def _log(
        self,
        level: LogLevel,
        msg: str,
        *,
        fields: dict[str, object] | None = None,
        extra: dict[str, object] | None = None,
    ) -> None:
        # Filtering: only emit if message level <= configured log_level.
        if level.value > self._log_level.value:
            return

        entry: dict[str, object] = {
            "ts": time.time(),
            "level": level.name,
            "severity": level.value,
            "msg": msg,
            "service": self._service_name,
            "trace_id": self._trace_id,
        }

        if self._span_id is not None:
            entry["span_id"] = self._span_id
        if self._request_id is not None:
            entry["request_id"] = self._request_id

        # Only when there is trace context to point at. A platform field naming a trace
        # that does not exist is worse than no field.
        if self._trace_field_formatter is not None and self._span_id is not None:
            entry.update(self._trace_field_formatter(self._trace_id, self._span_id))

        if extra is not None:
            entry.update(extra)
        if fields is not None:
            entry["fields"] = fields

        self._write_fn(json.dumps(entry))


def _level_for_status(status: int) -> LogLevel:
    """Map HTTP status code to RFC 5424 log level."""
    if status >= 500:
        return LogLevel.error
    if status >= 400:
        return LogLevel.warning
    if status >= 200:
        return LogLevel.info
    return LogLevel.notice  # 1xx
