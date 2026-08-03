"""The full pipeline, through a real request.

Python mirror of ``test/tracing/tracing_pipeline_test.dart``. The middleware tests exercise
``tracing_middleware`` directly; this exercises what ``ModularApi.build()`` actually assembles, which
is the only thing that can catch the host installing the middleware in the wrong place or not at all.

**The G3 group is why this file was added at the merge gate.** Dart asserted the structural half of
G3 — that absent ``tracing`` means nothing is installed, not "installed and idle" — through a real
request. TypeScript and Python asserted G3 only at the middleware and satellite level, so the host's
conditional was never exercised in either. D1 says a stage advances all three; this one had not.
"""

from __future__ import annotations

from collections.abc import Iterator

import pytest
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from starlette.testclient import TestClient

from modular_api import Field, Input, ModuleBuilder, Output, UseCase
from modular_api.core.modular_api import ModularApi
from modular_api.core.tracing.tracing_options import TracingOptions

_exporter = InMemorySpanExporter()
_provider = TracerProvider()
_provider.add_span_processor(SimpleSpanProcessor(_exporter))


class PingInput(Input):
    value: str = Field(default="ping", description="Anything", examples=["ping"])


class PingOutput(Output):
    echo: str = Field(description="Echo of the input", examples=["ping"])

    @property
    def status_code(self) -> int:
        return 200


class Ping(UseCase[PingInput, PingOutput]):
    def __init__(self, input_dto: PingInput) -> None:
        self._input = input_dto

    @property
    def input(self) -> PingInput:
        return self._input

    @classmethod
    def from_json(cls, json_value: dict[str, object]) -> Ping:
        return cls(PingInput.from_json(json_value))

    def validate(self) -> str | None:
        return None

    async def execute(self) -> PingOutput:
        return PingOutput(echo=self.input.value)


@pytest.fixture(autouse=True)
def _clear_spans() -> Iterator[None]:
    _exporter.clear()
    yield


def _app(tracing: TracingOptions | None):  # noqa: ANN202
    api = ModularApi(base_path="/api", title="modular_api-test", tracing=tracing)

    def build_cuenta(m: ModuleBuilder) -> None:
        m.usecase("ping", Ping.from_json)

    api.module("cuenta", build_cuenta)
    return api.build()


def _span_names() -> list[str]:
    return [span.name for span in _exporter.get_finished_spans()]


def _options() -> TracingOptions:
    return TracingOptions(tracer_provider=_provider)


# --- with TracingOptions ----------------------------------------------------


def test_a_request_through_the_real_pipeline_produces_a_server_span() -> None:
    with TestClient(_app(_options())) as client:
        client.post("/api/cuenta/ping", json={"value": "ping"})

    assert "POST /api/cuenta/ping" in _span_names()


def test_the_span_carries_the_route_and_a_200_status() -> None:
    with TestClient(_app(_options())) as client:
        client.post("/api/cuenta/ping", json={"value": "ping"})

    span = next(s for s in _exporter.get_finished_spans() if s.name == "POST /api/cuenta/ping")
    attributes = span.attributes or {}

    assert attributes["url.path"] == "/api/cuenta/ping"
    assert attributes["http.response.status_code"] == 200


def test_operational_routes_produce_no_span() -> None:
    # Health, docs, openapi and metrics are noise in a trace store. The host derives the exclusion
    # list from the operational paths rather than hardcoding it, so this also guards that list
    # against drift.
    with TestClient(_app(_options())) as client:
        client.get("/api/health")

    assert _exporter.get_finished_spans() == ()


# --- without TracingOptions (gate G3) ---------------------------------------


def test_no_span_is_produced_at_all() -> None:
    # The structural half of G3: off means nothing installed, not "installed and idle". Even a no-op
    # tracer would have produced span objects here.
    with TestClient(_app(None)) as client:
        response = client.post("/api/cuenta/ping", json={"value": "ping"})

    assert response.status_code == 200
    assert _exporter.get_finished_spans() == ()


def test_the_api_still_serves_normally() -> None:
    # Invariant 3: a REST-only API is valid with or without optional plugins.
    with TestClient(_app(None)) as client:
        response = client.post("/api/cuenta/ping", json={"value": "ping"})

    assert response.status_code == 200
    assert response.json() == {"echo": "ping"}
    # The home-grown correlation header is untouched by tracing being absent.
    assert response.headers.get("x-request-id") is not None
