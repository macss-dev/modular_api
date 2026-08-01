"""Emits the span shape one representative request produces, as JSON on stdout.

**Gate G6's input.** Three mirrored test suites can drift in a way no single-language test
catches: a test asserts the attributes that *are* there and never the ones that are not, so an
extra attribute in one language passes everywhere. This dump is compared key-for-key against
``code/tests/fixtures/tracing/span_shape.json`` by
``code/tests/integration_test/tracing_parity_test.ps1``, which makes the exact attribute set — not
a subset — the thing under test.

Ids, timestamps and durations are deliberately excluded: they differ every run and are the SDK's
business. Parentage is expressed by the parent's *name*, which is stable and is what a waterfall
actually shows.

Unlike the Dart and TypeScript counterparts this binds no port. ``api.serve`` is blocking here, so
the app is exercised through Starlette's ``TestClient`` — the same ASGI pipeline the host builds,
reached without a socket. That is a difference in how the request is made, not in what is measured.

Run: ``python -m tools.dump_span_shape`` with ``PYTHONPATH=src``
Counterparts: ``code/dart/modular_api/tool/dump_span_shape.dart``,
``code/ts/modular_api/tool/dumpSpanShape.ts``
"""

from __future__ import annotations

import json
import sys

from opentelemetry import trace
from opentelemetry.sdk.trace import ReadableSpan, TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from opentelemetry.trace import SpanKind
from starlette.testclient import TestClient

from modular_api import Field, Input, ModuleBuilder, Output, UseCase
from modular_api.core.modular_api import ModularApi
from modular_api.core.tracing.tracing_options import TracingOptions


class DetalleInput(Input):
    dni: str = Field(description="Document number", examples=["1"])


class DetalleOutput(Output):
    echo: str = Field(description="Echo of the input", examples=["1"])

    @property
    def status_code(self) -> int:
        return 200


class Detalle(UseCase[DetalleInput, DetalleOutput]):
    """Stands in for a handler that calls something downstream.

    The nested span is created with the plain OTel API and no argument threaded in: reaching the
    server span through ambient context alone is the mechanism ``macss-modular-api-rest-client``
    and ``macss-modular-api-postgres`` use, so comparing it across languages compares theirs too —
    without core depending on them.
    """

    def __init__(self, input_dto: DetalleInput) -> None:
        self._input = input_dto

    @property
    def input(self) -> DetalleInput:
        return self._input

    @classmethod
    def from_json(cls, json_value: dict[str, object]) -> Detalle:
        return cls(DetalleInput.from_json(json_value))

    def validate(self) -> str | None:
        return None

    async def execute(self) -> DetalleOutput:
        trace.get_tracer("span-shape").start_span(
            "upstream impulsa", kind=SpanKind.CLIENT
        ).end()
        return DetalleOutput(echo=self.input.dni)


def _parent_name(span: ReadableSpan, everything: list[ReadableSpan]) -> str | None:
    """The name of ``span``'s parent, or ``None`` when it is a root.

    By name rather than id, because ids are excluded from the fixture.
    """
    if span.parent is None:
        return None

    for candidate in everything:
        if candidate.context is not None and candidate.context.span_id == span.parent.span_id:
            return candidate.name
    return "<unknown>"


def main() -> None:
    exporter = InMemorySpanExporter()
    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    # Set globally so the use case's `trace.get_tracer` reaches this provider, which is what the
    # satellites rely on too.
    trace.set_tracer_provider(provider)

    api = ModularApi(
        base_path="/api",
        title="span-shape",
        tracing=TracingOptions(tracer_provider=provider),
    )

    def build_cuenta(m: ModuleBuilder) -> None:
        m.usecase("detalle", Detalle.from_json)

    api.module("cuenta", build_cuenta)

    with TestClient(api.build()) as client:
        client.post(
            "/api/cuenta/detalle",
            json={"dni": "12345678"},
            headers={
                # Sent so `http.request.header.x-request-id` is part of the shape. Without it the
                # attribute is conditionally absent in all three, and the comparison would not
                # cover the one attribute whose presence depends on the request.
                "x-request-id": "parity-fixture",
            },
        )

    captured = list(exporter.get_finished_spans())
    spans = sorted(
        (
            {
                "name": span.name,
                "kind": span.kind.name.lower(),
                "parent": _parent_name(span, captured),
                "attributeKeys": sorted((span.attributes or {}).keys()),
            }
            for span in captured
        ),
        key=lambda entry: entry["name"],
    )

    # Sentinel-prefixed, because the framework logs its own JSON lines to stdout and the harness
    # must not have to guess which line is the payload.
    sys.stdout.write("SPAN_SHAPE_JSON:" + json.dumps({"spans": spans}) + "\n")


if __name__ == "__main__":
    main()
