"""Python mirror of ``test/tracing_test.dart``.

**This is the stage that satisfies G7 for socia.** Its
``POST /api/cuenta/get-cuenta-detalle`` performs no database work at all — it is an HTTP
proxy to an upstream ``impulsa`` service (runbook D17) — so the client span is what shows
whether those 8–20 second bursts are spent in the outbound call or before it.

The propagator is set here, in the test, standing in for whatever the host configures
globally. The package under test never sets it: it reads ``propagate.inject``, which is what
lets it stay free of any dependency on the framework (runbook D21).
"""

from __future__ import annotations

import io
import json
import urllib.error
import urllib.request
from collections.abc import Iterator, Mapping
from email.message import Message
from typing import cast

import pytest
from opentelemetry import trace
from opentelemetry.propagate import set_global_textmap
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from opentelemetry.sdk.trace import ReadableSpan
from opentelemetry.trace import SpanContext, SpanKind, StatusCode
from opentelemetry.util.types import AttributeValue
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

from modular_api_rest_client.client import (
    HttpServiceClient,
    ServiceClientConfig,
    ServiceRequest,
)
from modular_api_rest_client.client_tracing import REQUEST_ID_HEADER

_exporter = InMemorySpanExporter()
_provider = TracerProvider()
_provider.add_span_processor(SimpleSpanProcessor(_exporter))
trace.set_tracer_provider(_provider)
set_global_textmap(TraceContextTextMapPropagator())

_tracer = _provider.get_tracer("test-host")

#: Headers the client actually sent, captured by the fake opener.
_sent: dict[str, str] = {}


@pytest.fixture(autouse=True)
def _reset() -> Iterator[None]:
    _exporter.clear()
    _sent.clear()
    yield


def _span_named(name: str) -> ReadableSpan | None:
    for span in _exporter.get_finished_spans():
        if span.name == name:
            return span
    return None


# The SDK types are honestly optional — a span may have no context, no attributes. A test that named a
# span and got nothing should say *that*, not fail with AttributeError on `None.trace_id` further down.
def _require_span(name: str) -> ReadableSpan:
    span = _span_named(name)
    assert span is not None, f"no span named {name!r} was exported"
    return span


def _attributes(span: ReadableSpan) -> Mapping[str, AttributeValue]:
    assert span.attributes is not None, f"span {span.name!r} carries no attributes"
    return span.attributes


def _context(span: ReadableSpan) -> SpanContext:
    assert span.context is not None, f"span {span.name!r} has no context"
    return span.context


def _parent(span: ReadableSpan) -> SpanContext:
    assert span.parent is not None, f"span {span.name!r} has no parent"
    return span.parent


class _FakeResponse(io.BytesIO):
    def __init__(self, status: int) -> None:
        super().__init__(json.dumps({"ok": True}).encode())
        self.status = status
        self.headers = _FakeHeaders()

    def getcode(self) -> int:
        return self.status

    def __enter__(self):  # noqa: ANN204
        return self

    def __exit__(self, *_args: object) -> None:
        return None


class _FakeHeaders:
    """What the client reads off a response: the content type and the header pairs.

    Not a `dict` subclass. It was one, with an `items()` that returned a list instead of a
    `dict_items` — a narrower return type than the base class promises, which is exactly the override
    a caller holding it as a `dict` would be broken by.
    """

    def get_content_type(self) -> str:
        return "application/json"

    def items(self) -> list[tuple[str, str]]:
        return []


class _FakeOpener:
    def __init__(self, status: int = 200, raises: BaseException | None = None) -> None:
        self._status = status
        self._raises = raises

    def open(self, request: urllib.request.Request, timeout: float | None = None):  # noqa: ANN201, ARG002
        _sent.update({key.lower(): value for key, value in request.header_items()})
        if self._raises is not None:
            raise self._raises
        return _FakeResponse(self._status)


def _client(
    *,
    status: int = 200,
    default_headers: dict[str, str] | None = None,
    raises: BaseException | None = None,
) -> HttpServiceClient:
    client = HttpServiceClient(
        ServiceClientConfig(
            service_id="impulsa",
            base_url="https://impulsa.example/api",
            redacted_summary="impulsa.example",
            default_headers=default_headers or {},
        )
    )
    # No injection seam exists for the opener, so the test reaches past the type. Recorded with a cast
    # rather than left as a silent mismatch: the fake implements `open()` and nothing else of
    # `OpenerDirector`, which is all the client calls.
    client._opener = cast("urllib.request.OpenerDirector", _FakeOpener(status=status, raises=raises))  # noqa: SLF001
    return client


def _call(client: HttpServiceClient, operation_id: str = "get-cuenta-detalle"):  # noqa: ANN201
    return client.execute(
        ServiceRequest(
            operation_id=operation_id,
            method="POST",
            path=operation_id,
            body={"dni": "12345678"},
        ),
        decoder=lambda json_value: json_value,
    )


def _within_server_span(body) -> None:  # noqa: ANN001
    server_span = _tracer.start_span(
        "POST /api/cuenta/get-cuenta-detalle", kind=SpanKind.SERVER
    )
    with trace.use_span(server_span, end_on_exit=True):
        body()


# --- with an active server span ---------------------------------------------


def test_emits_a_client_span_named_by_method_and_operation() -> None:
    _within_server_span(lambda: _call(_client()))

    assert _span_named("POST get-cuenta-detalle") is not None


def test_the_client_span_is_kind_client_and_a_child_of_the_server_span() -> None:
    _within_server_span(lambda: _call(_client()))

    server = _require_span("POST /api/cuenta/get-cuenta-detalle")
    client = _require_span("POST get-cuenta-detalle")

    assert client.kind is SpanKind.CLIENT
    assert _context(client).trace_id == _context(server).trace_id
    assert _parent(client).span_id == _context(server).span_id


def test_records_the_upstream_host_and_path_not_the_full_url() -> None:
    # A full URL can carry identifiers in its path or query. server.address plus url.path is
    # what the conventions ask for and what is safe to store.
    _within_server_span(lambda: _call(_client()))

    attributes = _attributes(_require_span("POST get-cuenta-detalle"))

    assert attributes["server.address"] == "impulsa.example"
    assert "get-cuenta-detalle" in str(attributes["url.path"])
    assert attributes["http.request.method"] == "POST"


def test_injects_traceparent_derived_from_the_client_span() -> None:
    # The header a downstream service would read. It names the CLIENT span, not the server
    # span, so a downstream hop attaches to the call rather than to its parent.
    _within_server_span(lambda: _call(_client()))

    client = _require_span("POST get-cuenta-detalle")
    traceparent = _sent.get("traceparent")

    assert traceparent is not None
    assert f"{_context(client).trace_id:032x}" in traceparent
    assert f"{_context(client).span_id:016x}" in traceparent


def test_a_500_from_upstream_sets_the_client_span_to_error() -> None:
    error = urllib.error.HTTPError(
        "https://impulsa.example/api", 500, "boom", Message(), io.BytesIO(b"")
    )
    _within_server_span(lambda: _call(_client(raises=error)))

    client = _require_span("POST get-cuenta-detalle")

    assert client.status.status_code is StatusCode.ERROR
    assert _attributes(client)["http.response.status_code"] == 500


def test_a_404_from_upstream_also_sets_error_unlike_a_server_span() -> None:
    # On a server span a 4xx is the caller's mistake. Here it means OUR outbound call failed,
    # which is a different thing and worth distinguishing in a waterfall.
    error = urllib.error.HTTPError(
        "https://impulsa.example/api", 404, "missing", Message(), io.BytesIO(b"")
    )
    _within_server_span(lambda: _call(_client(raises=error)))

    assert _require_span("POST get-cuenta-detalle").status.status_code is StatusCode.ERROR


def test_a_transport_failure_ends_the_span_with_error_and_no_status_code() -> None:
    # The case that matters for the socia investigation: a call that never returns.
    _within_server_span(
        lambda: _call(_client(raises=urllib.error.URLError("connection reset")))
    )

    client = _require_span("POST get-cuenta-detalle")

    assert client.status.status_code is StatusCode.ERROR
    assert "http.response.status_code" not in _attributes(client)


def test_the_span_is_ended_which_is_the_g7_measurement() -> None:
    # What the whole effort is for: separating "time spent calling impulsa" from "time spent
    # everywhere else". The number itself is production's to report.
    _within_server_span(lambda: _call(_client()))

    assert _require_span("POST get-cuenta-detalle").end_time is not None


# --- X-Request-ID forwarding (D23) ------------------------------------------


def test_an_inbound_request_id_is_forwarded_on_the_outbound_call() -> None:
    _within_server_span(
        lambda: _call(_client(default_headers={REQUEST_ID_HEADER: "order-42"}))
    )

    assert _sent[REQUEST_ID_HEADER] == "order-42"


def test_it_is_forwarded_even_with_tracing_off() -> None:
    # The half of D23 that repairs D20: impulsa does not run modular_api, so trace context
    # dies there. If it logs the request id, log correlation still crosses the boundary — and
    # that must not depend on tracing being enabled.
    _call(_client(default_headers={REQUEST_ID_HEADER: "order-42"}))

    assert _sent[REQUEST_ID_HEADER] == "order-42"


def test_none_is_invented_when_the_caller_sent_none() -> None:
    # We forward, we do not generate. Minting one belongs at an edge that knows it is the edge.
    _call(_client())

    assert REQUEST_ID_HEADER not in _sent


# --- without an active server span (gate G3) --------------------------------


def test_no_client_span_is_emitted() -> None:
    # Not "a non-recording span": none at all.
    _call(_client())

    assert _exporter.get_finished_spans() == ()


def test_no_traceparent_is_injected() -> None:
    # A header naming a span that does not exist would mislead a downstream service into
    # attaching to nothing.
    _call(_client())

    assert "traceparent" not in _sent


def test_the_call_still_succeeds() -> None:
    result = _call(_client())

    assert result.is_success
