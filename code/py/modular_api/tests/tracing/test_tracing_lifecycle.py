"""Python mirror of ``test/tracing/tracing_lifecycle_test.dart``.

**There is deliberately no tracing plugin** (ADR-0005 A7). Every responsibility decision 4
assigned to one was reassigned: A2 moved the sampler, processor and exporter to the
application; the span became host-owned so no middleware is registered; the shutdown became
a callback; and D14 removed the dropped-span counter. The host reads ``TracingOptions``
directly.

D8's revision is starker here than in Dart, as it is in TypeScript:
``opentelemetry.trace.TracerProvider`` exposes only ``get_tracer``. The framework *could
not* flush the provider even if it wanted to, which is half of why the responsibility moved
to the application.

The shutdown hook lives in the Starlette lifespan, so these tests drive it by entering and
leaving the ``TestClient`` context — which is what actually triggers startup and shutdown.
"""

from __future__ import annotations

from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from starlette.testclient import TestClient

from modular_api.core.modular_api import ModularApi
from modular_api.core.tracing.tracing_options import TracingOptions

_exporter = InMemorySpanExporter()
_provider = TracerProvider()
_provider.add_span_processor(SimpleSpanProcessor(_exporter))


def _options(on_shutdown=None) -> TracingOptions:  # noqa: ANN001
    return TracingOptions(tracer_provider=_provider, on_shutdown=on_shutdown)


def _serve_and_close(tracing: TracingOptions | None) -> None:
    api = ModularApi(base_path="/api", title="modular_api-test", tracing=tracing)
    app = api.build()
    # Entering and leaving the context runs the lifespan, which is where the hook lives.
    with TestClient(app):
        pass


# --- shutdown timing (D8 as revised) ----------------------------------------


def test_on_shutdown_runs_when_the_server_closes() -> None:
    # On Cloud Run this is the only window before the container dies. The framework supplies
    # the moment; the application supplies the action.
    calls: list[int] = []

    _serve_and_close(_options(on_shutdown=lambda: calls.append(1)))

    assert calls == [1]


def test_an_async_on_shutdown_is_awaited() -> None:
    # Python is the only one of the three where the callback may be sync or async, because
    # both are idiomatic here. Both are supported rather than forcing a coroutine.
    calls: list[str] = []

    async def flush() -> None:
        calls.append("flushed")

    _serve_and_close(_options(on_shutdown=flush))

    assert calls == ["flushed"]


def test_a_missing_on_shutdown_is_not_an_error() -> None:
    _serve_and_close(_options())


def test_an_on_shutdown_that_raises_does_not_prevent_shutdown() -> None:
    # A failing flush must not turn a clean shutdown into a crash.
    def boom() -> None:
        raise RuntimeError("flush failed")

    _serve_and_close(_options(on_shutdown=boom))


def test_the_framework_does_not_shut_down_the_provider_itself() -> None:
    # It could not: TracerProvider in opentelemetry-api exposes only get_tracer. Asserting
    # it anyway, because the test states the intent rather than the accident.
    _serve_and_close(_options())

    span = _provider.get_tracer("after-shutdown").start_span("still-working")
    span.end()

    assert span.get_span_context().is_valid


# --- configuration ----------------------------------------------------------


def test_the_instrumentation_name_defaults_to_modular_api() -> None:
    assert _options().instrumentation_name == "modular_api"


def test_the_instrumentation_name_can_be_overridden() -> None:
    options = TracingOptions(
        tracer_provider=_provider, instrumentation_name="socia-api"
    )

    assert options.instrumentation_name == "socia-api"
