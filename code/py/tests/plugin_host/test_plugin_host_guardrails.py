from __future__ import annotations

import json
from typing import Any

import pytest
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route
from starlette.testclient import TestClient
from starlette.types import ASGIApp, Receive, Scope, Send

from modular_api import Input, Output, Plugin, PluginHost, PluginManifest, PluginMiddleware, RuntimePluginHost, UseCase
from modular_api.core.error_response_middleware import error_response_middleware
from modular_api.core.logger.logger import LogLevel
from modular_api.core.logger.logging_middleware import logging_middleware
from modular_api.core.registry import api_registry
from modular_api.core.usecase_handler import usecase_handler


@pytest.fixture(autouse=True)
def _clean_registry() -> None:
    api_registry.clear()
    yield
    api_registry.clear()


def test_annotates_the_completed_request_log_when_plugin_middleware_short_circuits_before_the_core_handler() -> None:
    events: list[str] = []
    captured_logs: list[str] = []
    app = build_guardrail_app(
        plugins=[
            MiddlewarePlugin(
                "acme.guard",
                [
                    PluginMiddleware(
                        id="acme.guard.auth",
                        slot="preHandler",
                        order=0,
                        handler=make_short_circuit_middleware(401, {"error": "blocked by plugin"}),
                    )
                ],
            )
        ],
        events=events,
        captured_logs=captured_logs,
    )

    client = TestClient(app)
    response = client.post(
        "/api/demo/pipeline",
        headers={"X-Request-ID": "trace-py-short-circuit"},
        json={"name": "Ada"},
    )

    assert response.status_code == 401
    assert response.json() == {"error": "blocked by plugin"}
    assert events == []

    completed_log = json.loads(captured_logs[-1])
    assert completed_log["msg"] == "request completed"
    assert completed_log["trace_id"] == "trace-py-short-circuit"
    assert completed_log["short_circuit"] is True
    assert completed_log["short_circuit_plugin_id"] == "acme.guard"
    assert completed_log["short_circuit_middleware_id"] == "acme.guard.auth"
    assert completed_log["short_circuit_slot"] == "preHandler"


def test_returns_a_normalized_500_json_response_when_plugin_middleware_throws_outside_the_core_handler() -> None:
    events: list[str] = []
    captured_logs: list[str] = []
    app = build_guardrail_app(
        plugins=[
            MiddlewarePlugin(
                "acme.guard",
                [
                    PluginMiddleware(
                        id="acme.guard.boom",
                        slot="preHandler",
                        order=0,
                        handler=make_crashing_middleware("boom"),
                    )
                ],
            )
        ],
        events=events,
        captured_logs=captured_logs,
    )

    client = TestClient(app)
    response = client.post(
        "/api/demo/pipeline",
        headers={"X-Request-ID": "trace-py-error-guardrail"},
        json={"name": "Ada"},
    )

    assert response.status_code == 500
    assert response.json() == {"error": "Internal server error"}
    assert events == []

    parsed_logs = [json.loads(line) for line in captured_logs]
    error_log = next(line for line in parsed_logs if line["msg"] == "Unhandled error in request pipeline")
    assert error_log["trace_id"] == "trace-py-error-guardrail"
    assert error_log["level"] == "error"
    assert error_log["fields"] == {"error": "boom", "status": 500}

    completed_log = parsed_logs[-1]
    assert completed_log["msg"] == "request completed"
    assert completed_log["status"] == 500
    assert "short_circuit" not in completed_log


def build_guardrail_app(*, plugins: list[Plugin], events: list[str], captured_logs: list[str]) -> Starlette:
    host = RuntimePluginHost(base_path="/api", title="Guardrail Test API", version="0.1.0")

    for plugin in plugins:
        host.begin_plugin_setup(plugin.manifest.id)
        plugin.setup(host)
        host.end_plugin_setup()

    host.freeze()
    host.assert_valid()

    app = Starlette(
        routes=[
            Route(
                "/api/demo/pipeline",
                endpoint=usecase_handler(lambda json_body: GuardrailUseCase(GuardrailInput(name=str(json_body.get("name", ""))), events)),
                methods=["POST"],
            )
        ]
    )

    for middleware in reversed(host.middlewares_for_slot("postHandler")):
        app.add_middleware(middleware.handler)
    for middleware in reversed(host.middlewares_for_slot("preHandler")):
        app.add_middleware(middleware.handler)
    for middleware in reversed(host.middlewares_for_slot("preRouting")):
        app.add_middleware(middleware.handler)
    app.add_middleware(error_response_middleware())
    app.add_middleware(
        logging_middleware(
            log_level=LogLevel.debug,
            service_name="guardrail-test",
            write_fn=captured_logs.append,
        )
    )

    return app


class GuardrailInput(Input):
    name: str = ""


class GuardrailOutput(Output):
    message: str = "ok"

    @property
    def status_code(self) -> int:
        return 200


class GuardrailUseCase(UseCase[GuardrailInput, GuardrailOutput]):
    def __init__(self, inp: GuardrailInput, events: list[str]) -> None:
        self._input = inp
        self._events = events

    @property
    def input(self) -> GuardrailInput:
        return self._input

    def validate(self) -> str | None:
        self._events.append("validate")
        return None

    async def execute(self) -> GuardrailOutput:
        self._events.append("execute")
        return GuardrailOutput(message=f"Hello, {self.input.name}")


class MiddlewarePlugin(Plugin):
    def __init__(self, plugin_id: str, definitions: list[PluginMiddleware]) -> None:
        self.manifest = PluginManifest(
            id=plugin_id,
            display_name="Middleware Plugin",
            version="0.1.0",
            host_api_version=">=0.1.0 <0.2.0",
        )
        self._definitions = definitions

    def setup(self, host: PluginHost) -> None:
        for definition in self._definitions:
            host.register_middleware(definition)


def make_short_circuit_middleware(status_code: int, body: dict[str, Any]) -> type:
    class _ShortCircuitMiddleware:
        def __init__(self, app: ASGIApp) -> None:
            self.app = app

        async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
            if scope["type"] != "http":
                await self.app(scope, receive, send)
                return

            response = JSONResponse(body, status_code=status_code)
            await response(scope, receive, send)

    return _ShortCircuitMiddleware


def make_crashing_middleware(message: str) -> type:
    class _CrashingMiddleware:
        def __init__(self, app: ASGIApp) -> None:
            self.app = app

        async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
            if scope["type"] != "http":
                await self.app(scope, receive, send)
                return

            raise RuntimeError(message)

    return _CrashingMiddleware