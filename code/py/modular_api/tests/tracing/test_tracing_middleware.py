"""Python mirror of ``test/tracing/tracing_middleware_test.dart``.

The official SDK is a **test dependency only** (runbook D22): with just the API
installed spans are no-ops that record nothing, so a real tracer provider is the only
way instrumentation is observable. ``opentelemetry-sdk`` ships the in-memory exporter,
so nothing here is hand-written — the same reason contribution #2 was withdrawn.

The case this stage exists for is the enclosure regression test: a plugin middleware
must run inside the server span's window.
"""

from __future__ import annotations

from collections.abc import Iterator

import pytest
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from opentelemetry.trace import SpanKind, StatusCode
from starlette.applications import Starlette
from starlette.responses import PlainTextResponse
from starlette.routing import Route
from starlette.testclient import TestClient

from modular_api.core.tracing.propagation_policy import REQUEST_ID_HEADER
from modular_api.core.tracing.tracing_middleware import (
    PROPAGATION_RESULT_SCOPE_KEY,
    TRACING_SPAN_SCOPE_KEY,
    tracing_middleware,
)

TRACE_ID = "4bf92f3577b34da6a3ce929d0e0e4736"
PARENT_SPAN_ID = "00f067aa0ba902b7"
TRACEPARENT = f"00-{TRACE_ID}-{PARENT_SPAN_ID}-01"

_exporter = InMemorySpanExporter()
_provider = TracerProvider()
_provider.add_span_processor(SimpleSpanProcessor(_exporter))
_tracer = _provider.get_tracer("modular_api-test")


@pytest.fixture(autouse=True)
def _clear_spans() -> Iterator[None]:
    _exporter.clear()
    yield


def _span_named(name: str):
    for span in _exporter.get_finished_spans():
        if span.name == name:
            return span
    return None


def _app(
    handler=None,
    *,
    status: int = 200,
    excluded_routes: tuple[str, ...] = (),
    inner: tuple = (),
) -> Starlette:
    """Builds the app the host builds: tracing outermost, then plugin middlewares."""

    async def default_handler(request):  # noqa: ANN001, ANN202
        return PlainTextResponse("ok", status_code=status)

    app = Starlette(routes=[Route("/api/cuenta/ping", handler or default_handler)])

    # Starlette is LIFO: last added is outermost. Inner middlewares are added first so
    # tracing ends up outside them, exactly as the host does it.
    for middleware in inner:
        app.add_middleware(middleware)
    app.add_middleware(
        tracing_middleware(tracer=_tracer, excluded_routes=excluded_routes)
    )
    return app


def _get(app: Starlette, path: str = "/api/cuenta/ping", **kwargs):  # noqa: ANN003
    with TestClient(app, raise_server_exceptions=False) as client:
        return client.get(path, **kwargs)


# --- the server span --------------------------------------------------------


def test_is_emitted_for_a_request_named_by_method_and_route() -> None:
    _get(_app())

    assert _span_named("GET /api/cuenta/ping") is not None


def test_is_a_server_span() -> None:
    _get(_app())

    assert _span_named("GET /api/cuenta/ping").kind is SpanKind.SERVER


def test_carries_method_path_and_status_code_attributes() -> None:
    _get(_app())

    attributes = _span_named("GET /api/cuenta/ping").attributes

    assert attributes["http.request.method"] == "GET"
    assert attributes["url.path"] == "/api/cuenta/ping"
    assert attributes["http.response.status_code"] == 200


def test_records_the_request_id_when_the_caller_sent_one() -> None:
    _get(_app(), headers={REQUEST_ID_HEADER: "order-42"})

    attributes = _span_named("GET /api/cuenta/ping").attributes
    assert attributes["http.request.header.x-request-id"] == "order-42"


def test_omits_the_request_id_attribute_when_none_was_sent() -> None:
    _get(_app())

    attributes = _span_named("GET /api/cuenta/ping").attributes
    assert "http.request.header.x-request-id" not in attributes


# --- parenting --------------------------------------------------------------


def test_is_a_child_of_an_incoming_traceparent() -> None:
    # The precondition for reading cold start as a gap: our span must attach to the
    # platform's request span rather than starting a new trace.
    _get(_app(), headers={"traceparent": TRACEPARENT})

    span = _span_named("GET /api/cuenta/ping")

    assert f"{span.context.trace_id:032x}" == TRACE_ID
    assert f"{span.parent.span_id:016x}" == PARENT_SPAN_ID


def test_is_a_root_span_when_no_trace_header_arrives() -> None:
    _get(_app())

    span = _span_named("GET /api/cuenta/ping")

    assert f"{span.context.trace_id:032x}" != TRACE_ID
    assert span.parent is None


# --- status -----------------------------------------------------------------


def test_a_5xx_response_sets_the_span_status_to_error() -> None:
    _get(_app(status=503))

    assert _span_named("GET /api/cuenta/ping").status.status_code is StatusCode.ERROR


def test_a_4xx_response_does_not_set_error_status() -> None:
    # A client mistake is not a server failure. Marking 404s as errors makes an
    # error-rate panel useless.
    _get(_app(status=404))

    assert _span_named("GET /api/cuenta/ping").status.status_code is not StatusCode.ERROR


def test_a_handler_that_raises_ends_the_span_with_error_status() -> None:
    async def boom(request):  # noqa: ANN001, ANN202
        raise RuntimeError("boom")

    _get(_app(boom))

    span = _span_named("GET /api/cuenta/ping")
    assert span is not None
    assert span.end_time is not None
    assert span.status.status_code is StatusCode.ERROR


# --- the span encloses everything inside it ---------------------------------


def test_a_plugin_middleware_runs_within_the_server_span_window() -> None:
    # THE regression test for ADR-0005 decision 4. A span created from inside a plugin
    # slot would start after this middleware had already run, leaving the waterfall
    # blind to exactly the early work that matters.
    observed: list[bool] = []

    def plugin_middleware(app):  # noqa: ANN001, ANN202
        async def middleware(scope, receive, send):  # noqa: ANN001, ANN202
            # Only HTTP scopes. An ASGI middleware also sees the `lifespan` scope, and
            # a first draft of this test recorded that too -- reading [False, True]
            # instead of [True], because there is no span during startup. The failure
            # was the test's, not the middleware's, and it is a reminder that ASGI
            # middleware must filter on scope type.
            if scope["type"] != "http":
                await app(scope, receive, send)
                return

            # The span exists and is active by the time a plugin middleware runs, which
            # is the portable form of "the span encloses this" (G6).
            from opentelemetry import trace as otel_trace

            observed.append(otel_trace.get_current_span().is_recording())
            await app(scope, receive, send)

        return middleware

    _get(_app(inner=(plugin_middleware,)))

    assert observed == [True]


def test_the_span_is_ambient_for_downstream_code() -> None:
    # What makes Stages 8 and 9 possible without threading a span through call
    # signatures. Python needs nothing registered for this: contextvars propagate
    # through async natively, unlike JavaScript where a missing ContextManager
    # silently turns children into roots.
    async def handler(request):  # noqa: ANN001, ANN202
        _tracer.start_span("downstream.work").end()
        return PlainTextResponse("ok")

    _get(_app(handler))

    parent = _span_named("GET /api/cuenta/ping")
    child = _span_named("downstream.work")

    assert child.context.trace_id == parent.context.trace_id
    assert child.parent.span_id == parent.context.span_id


def test_exposes_the_span_and_the_propagation_result_in_the_scope() -> None:
    captured: dict[str, object] = {}

    async def handler(request):  # noqa: ANN001, ANN202
        captured["span"] = request.scope.get(TRACING_SPAN_SCOPE_KEY)
        captured["propagation"] = request.scope.get(PROPAGATION_RESULT_SCOPE_KEY)
        return PlainTextResponse("ok")

    _get(_app(handler), headers={REQUEST_ID_HEADER: "order-42"})

    assert captured["span"] is not None
    assert captured["propagation"].request_id == "order-42"


# --- excluded routes --------------------------------------------------------


def test_excluded_routes_produce_no_span() -> None:
    _get(_app(excluded_routes=("/api/cuenta/ping",)))

    assert _exporter.get_finished_spans() == ()


def test_excluded_routes_still_reach_the_handler() -> None:
    response = _get(_app(excluded_routes=("/api/cuenta/ping",)))

    assert response.status_code == 200
    assert response.text == "ok"
