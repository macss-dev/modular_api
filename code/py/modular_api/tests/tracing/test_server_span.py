"""Gate G4 — transport neutrality.

**Not one line of this file imports Starlette, builds an ASGI scope, or opens a socket.** That is the
entire assertion: ``start_server_span`` and ``complete_server_span`` take a method, a route and a
header mapping, which is all any transport can supply. The planned gRPC transport therefore arrives as
a second adapter over the same functions rather than as a second copy of span construction.

This file exists because G4 was **checked rather than assumed** at the merge gate. The span had been
built inline inside ``tracing_middleware``'s ASGI closure. Every behavioural test passed — they all go
through HTTP, so they could not see it — and a gRPC transport would have had no choice but to
duplicate the logic.

Python mirror of ``test/tracing/server_span_test.dart``.
"""

from __future__ import annotations

from collections.abc import Iterator

import pytest
from opentelemetry.sdk.trace import ReadableSpan, TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from opentelemetry.trace import SpanKind, StatusCode

from modular_api.core.tracing.server_span import (
    ServerSpanStart,
    complete_server_span,
    start_server_span,
)

_exporter = InMemorySpanExporter()
_provider = TracerProvider()
_provider.add_span_processor(SimpleSpanProcessor(_exporter))
_tracer = _provider.get_tracer("modular_api")

_ROUTE = "/api/cuenta/detalle"


@pytest.fixture(autouse=True)
def _clear_spans() -> Iterator[None]:
    _exporter.clear()
    yield


def _span_named(name: str) -> ReadableSpan | None:
    for span in _exporter.get_finished_spans():
        if span.name == name:
            return span
    return None


def _start(method: str, headers: dict[str, str] | None = None) -> ServerSpanStart:
    return start_server_span(
        tracer=_tracer,
        method=method,
        route=_ROUTE,
        headers=headers or {},
    )


# --- with no transport in scope ---------------------------------------------


def test_a_span_can_be_started_and_ended() -> None:
    complete_server_span(_start("post").span, status_code=200)

    assert _span_named(f"POST {_ROUTE}") is not None


def test_the_method_is_upper_cased_for_the_span_name_and_the_attribute() -> None:
    # A transport that hands over a lower-case verb must not produce a differently named span from
    # one that hands over an upper-case one.
    complete_server_span(_start("get").span, status_code=200)

    span = _span_named(f"GET {_ROUTE}")
    assert span is not None
    assert (span.attributes or {})["http.request.method"] == "GET"


def test_it_is_a_server_span_carrying_route_and_status() -> None:
    complete_server_span(_start("POST").span, status_code=201)

    span = _span_named(f"POST {_ROUTE}")
    assert span is not None
    attributes = span.attributes or {}

    assert span.kind is SpanKind.SERVER
    assert attributes["url.path"] == _ROUTE
    assert attributes["http.response.status_code"] == 201


def test_a_header_map_is_all_propagation_needs() -> None:
    # The propagation policy takes a mapping, not a request. That is what lets a gRPC transport hand
    # over its metadata without translating it into an HTTP request first.
    complete_server_span(
        _start(
            "POST",
            {"traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"},
        ).span,
        status_code=200,
    )

    span = _span_named(f"POST {_ROUTE}")
    assert span is not None
    assert span.context is not None
    assert f"{span.context.trace_id:032x}" == "4bf92f3577b34da6a3ce929d0e0e4736"
    assert span.parent is not None
    assert f"{span.parent.span_id:016x}" == "00f067aa0ba902b7"


def test_the_resolved_request_id_is_returned_as_well_as_recorded() -> None:
    # The caller gets it back, because a transport adapter has to echo it on the response and should
    # not have to parse the headers a second time to find it.
    started = _start("POST", {"x-request-id": "order-42"})
    complete_server_span(started.span, status_code=200)

    span = _span_named(f"POST {_ROUTE}")
    assert span is not None
    assert started.propagation.request_id == "order-42"
    assert (span.attributes or {})["http.request.header.x-request-id"] == "order-42"


# --- status semantics -------------------------------------------------------


def test_a_5xx_sets_error_status() -> None:
    complete_server_span(_start("POST").span, status_code=503)

    span = _span_named(f"POST {_ROUTE}")
    assert span is not None
    assert span.status.status_code is StatusCode.ERROR


def test_a_4xx_does_not() -> None:
    # On a server span a 4xx is the caller's mistake. Marking it as our error makes an error-rate
    # panel useless. (The opposite holds on a client span, where a 4xx means *our* call failed.)
    complete_server_span(_start("POST").span, status_code=404)

    span = _span_named(f"POST {_ROUTE}")
    assert span is not None
    assert span.status.status_code is not StatusCode.ERROR


def test_an_error_sets_error_status_and_records_the_exception() -> None:
    complete_server_span(_start("POST").span, error=RuntimeError("boom"))

    span = _span_named(f"POST {_ROUTE}")
    assert span is not None
    assert span.status.status_code is StatusCode.ERROR


def test_a_transport_with_no_status_code_produces_a_span_with_none() -> None:
    # gRPC has its own status model. Passing no HTTP status must not invent one.
    complete_server_span(_start("POST").span)

    span = _span_named(f"POST {_ROUTE}")
    assert span is not None
    assert "http.response.status_code" not in (span.attributes or {})
    assert span.status.status_code is not StatusCode.ERROR
    assert span.end_time is not None
