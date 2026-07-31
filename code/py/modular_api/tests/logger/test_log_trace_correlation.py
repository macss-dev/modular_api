"""Python mirror of ``test/logger/log_trace_correlation_test.dart``.

The tracing middleware is outermost and ``logging_middleware`` runs inside it (runbook
D12 as reversed), so a recording span is already active when the logger is created and
contextvars keep it active when it emits ``request completed``. Every line reads
``trace_id`` and ``span_id`` from the ambient span, with nothing mutated afterwards.

The first design had these the other way round, which forced the logger to own the trace
id and the span to adopt it. That was expressible in Dart and not in TypeScript, where
seeding a trace id means seeding a *parent* whose trace flags made the sampler drop the
span. The failing TypeScript test produced the reversal; this file is written against the
result.
"""

from __future__ import annotations

import json
from collections.abc import Iterator

import pytest
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from starlette.applications import Starlette
from starlette.responses import PlainTextResponse
from starlette.routing import Route
from starlette.testclient import TestClient

from modular_api.core.logger.logger import LogLevel
from modular_api.core.logger.logging_middleware import logging_middleware
from modular_api.core.tracing.propagation_policy import REQUEST_ID_HEADER
from modular_api.core.tracing.tracing_middleware import tracing_middleware
from modular_api.core.tracing.tracing_options import TracingOptions

TRACE_ID = "4bf92f3577b34da6a3ce929d0e0e4736"
TRACEPARENT = f"00-{TRACE_ID}-00f067aa0ba902b7-01"
UUID_PATTERN = (
    r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)

_exporter = InMemorySpanExporter()
_provider = TracerProvider()
_provider.add_span_processor(SimpleSpanProcessor(_exporter))
_options = TracingOptions(tracer_provider=_provider)


@pytest.fixture(autouse=True)
def _clear_spans() -> Iterator[None]:
    _exporter.clear()
    yield


def _logs_for(
    *,
    tracing: TracingOptions | None = None,
    headers: dict[str, str] | None = None,
    trace_field_formatter=None,  # noqa: ANN001
) -> list[dict[str, object]]:
    captured: list[dict[str, object]] = []

    async def handler(request):  # noqa: ANN001, ANN202
        return PlainTextResponse("ok")

    app = Starlette(routes=[Route("/api/cuenta/ping", handler)])

    # Starlette is LIFO: logging is added first so tracing ends up outside it, which is
    # the order the host builds.
    app.add_middleware(
        logging_middleware(
            log_level=LogLevel.debug,
            service_name="modular_api-test",
            write_fn=lambda line: captured.append(json.loads(line)),
            trace_field_formatter=trace_field_formatter,
        ),
    )
    if tracing is not None:
        app.add_middleware(
            tracing_middleware(tracer=tracing.tracer, policy=tracing.policy),
        )

    with TestClient(app) as client:
        client.get("/api/cuenta/ping", headers=headers or {})

    return captured


def _line(logs: list[dict[str, object]], msg: str) -> dict[str, object]:
    return next(log for log in logs if log["msg"] == msg)


def _span_named(name: str):
    for span in _exporter.get_finished_spans():
        if span.name == name:
            return span
    return None


# --- without TracingOptions: the compatibility guarantee (D5b) ---------------


def test_trace_id_keeps_its_uuid_shape() -> None:
    # The whole point of gating the format change on adoption: a consumer who does not
    # enable tracing sees exactly what they saw before, so no log query, no dashboard and
    # no alert breaks.
    logs = _logs_for()

    assert logs
    import re

    assert re.match(UUID_PATTERN, str(logs[0]["trace_id"]))


def test_an_incoming_traceparent_is_ignored_not_adopted() -> None:
    logs = _logs_for(headers={"traceparent": TRACEPARENT})

    assert logs[0]["trace_id"] != TRACE_ID


def test_no_span_id_is_emitted() -> None:
    logs = _logs_for()

    assert "span_id" not in logs[0]


def test_request_id_header_is_still_the_trace_id_as_it_always_was() -> None:
    logs = _logs_for(headers={REQUEST_ID_HEADER: "legacy-correlation"})

    assert logs[0]["trace_id"] == "legacy-correlation"


# --- with TracingOptions ----------------------------------------------------


def test_trace_id_is_the_32_hex_w3c_id() -> None:
    logs = _logs_for(tracing=_options, headers={"traceparent": TRACEPARENT})

    assert logs[0]["trace_id"] == TRACE_ID


def test_trace_id_is_a_generated_32_hex_id_when_no_header_arrives() -> None:
    import re

    logs = _logs_for(tracing=_options)

    assert re.match(r"^[0-9a-f]{32}$", str(logs[0]["trace_id"]))


def test_request_id_carries_the_original_header() -> None:
    # D6: the caller's token is preserved beside the trace id rather than promoted into it,
    # so anyone correlating by what they sent keeps working.
    logs = _logs_for(tracing=_options, headers={REQUEST_ID_HEADER: "order-42"})

    assert logs[0]["request_id"] == "order-42"
    assert logs[0]["trace_id"] != "order-42"


def test_request_id_is_absent_when_the_caller_sent_none() -> None:
    logs = _logs_for(tracing=_options)

    assert "request_id" not in logs[0]


def test_the_trace_id_in_the_log_equals_the_exported_span_trace_id() -> None:
    # The assertion the whole stage exists for. If these two ever disagree, a log line
    # points at a trace that does not contain it.
    logs = _logs_for(tracing=_options)

    span = _span_named("GET /api/cuenta/ping")
    assert logs[0]["trace_id"] == f"{span.context.trace_id:032x}"


def test_span_id_is_emitted_on_lines_logged_while_the_span_is_active() -> None:
    logs = _logs_for(tracing=_options)

    span = _span_named("GET /api/cuenta/ping")
    completed = _line(logs, "request completed")
    assert completed["span_id"] == f"{span.context.span_id:016x}"


def test_span_id_reaches_the_request_completed_line() -> None:
    # The line that matters most: it carries duration_ms. It is emitted from inside the
    # span's active scope, so contextvars still hold the span.
    logs = _logs_for(tracing=_options)
    completed = _line(logs, "request completed")

    assert completed["duration_ms"] is not None
    assert completed["span_id"] is not None


def test_span_id_reaches_request_received_too() -> None:
    # A limit the earlier design accepted as inevitable and the reversal removed: with
    # tracing outermost the span exists before the logger, so the first line correlates as
    # fully as the last.
    logs = _logs_for(tracing=_options)
    received = _line(logs, "request received")

    assert received["span_id"] is not None
    assert received["trace_id"] is not None


# --- the platform correlation field -----------------------------------------


def test_the_platform_field_is_absent_by_default() -> None:
    # Roadmap invariant 7: the framework emits open formats and nothing vendor-specific.
    logs = _logs_for(tracing=_options)

    assert not any("googleapis" in key for key in logs[0])


def test_the_platform_field_is_emitted_when_a_formatter_is_supplied() -> None:
    logs = _logs_for(
        tracing=_options,
        # What socia supplies: the GCP field, built from ids the framework resolved and a
        # project id only the application knows.
        trace_field_formatter=lambda trace_id, span_id: {
            "logging.googleapis.com/trace": f"projects/sociacacsi/traces/{trace_id}",
            **({} if span_id is None else {"logging.googleapis.com/spanId": span_id}),
        },
    )

    completed = _line(logs, "request completed")
    assert str(completed["logging.googleapis.com/trace"]).startswith(
        "projects/sociacacsi/traces/"
    )
    assert completed["logging.googleapis.com/spanId"] is not None


def test_the_platform_field_is_not_emitted_without_tracing() -> None:
    # A formatter with no trace context to format would produce a field pointing at a
    # trace that does not exist.
    logs = _logs_for(
        trace_field_formatter=lambda trace_id, span_id: {
            "logging.googleapis.com/trace": f"projects/x/traces/{trace_id}",
        },
    )

    assert "logging.googleapis.com/trace" not in logs[0]
