from __future__ import annotations

from typing import Any

import pytest
from starlette.requests import Request
from starlette.responses import Response
from starlette.testclient import TestClient
from starlette.types import ASGIApp, Receive, Scope, Send

from modular_api import (
    Capability,
    Input,
    ModularApi,
    Output,
    Plugin,
    PluginHost,
    PluginHostError,
    PluginManifest,
    PluginMiddleware,
    PluginRoute,
    UseCase,
)
from modular_api.core.logger.logging_middleware import LOGGER_STATE_KEY
from modular_api.core.registry import api_registry


@pytest.fixture(autouse=True)
def _clean_registry() -> None:
    api_registry.clear()
    yield
    api_registry.clear()


def test_orders_middleware_by_slot_order_and_setup_order_without_bypassing_usecase_lifecycle() -> None:
    events: list[str] = []
    api = ModularApi(base_path="/api", title="Stage 4 API")
    api.plugin(
        MiddlewarePlugin(
            "acme.first",
            [recording_middleware_definition("preHandler:first", "preHandler", 5, events)],
        )
    )
    api.plugin(
        MiddlewarePlugin(
            "acme.second",
            [recording_middleware_definition("preHandler:second", "preHandler", 5, events)],
        )
    )
    api.plugin(
        MiddlewarePlugin(
            "acme.low",
            [
                logging_probe_middleware_definition(events),
                recording_middleware_definition("preHandler:low", "preHandler", 1, events),
                recording_middleware_definition("postHandler:low", "postHandler", 0, events),
            ],
        )
    )
    api.use(make_recording_middleware("custom", events))
    api.module("demo", lambda m: m.usecase("pipeline", lambda json: Stage4UseCase(Stage4Input(name=str(json.get("name", ""))), events)))

    client = TestClient(api.build())
    response = client.post(
        "/api/demo/pipeline",
        headers={"X-Request-ID": "trace-stage4-order"},
        json={"name": "Ada"},
    )

    assert response.status_code == 200
    assert events == [
        "preRouting:logger",
        "custom",
        "preHandler:low",
        "preHandler:first",
        "preHandler:second",
        "postHandler:low",
        "validate",
        "execute",
    ]


def test_rejects_unknown_middleware_slots_during_startup() -> None:
    api = ModularApi(base_path="/api")
    api.plugin(
        MiddlewarePlugin(
            "acme.invalid",
            [recording_middleware_definition("invalid", "moonPhase", 0, [])],
        )
    )

    with pytest.raises(PluginHostError) as excinfo:
        api.build()

    assert excinfo.value.code == "PLUGIN_VALIDATION_FAILED"


def test_passes_a_full_request_context_to_plugin_route_handlers() -> None:
    api = ModularApi(base_path="/api")
    api.plugin(ContextRoutePlugin())

    client = TestClient(api.build())
    response = client.post(
        "/api/plugin-context/alice?lang=py",
        headers={"X-Request-ID": "trace-stage4-context", "X-Stage4": "present"},
        json={"hello": "world"},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["requestId"] == "trace-stage4-context"
    assert body["loggerPresent"] is True
    assert body["method"] == "POST"
    assert body["path"] == "/api/plugin-context/alice"
    assert body["stageHeader"] == "present"
    assert body["queryLang"] == "py"
    assert body["bodyHello"] == "world"
    assert body["pathName"] == "alice"
    assert "acme.capability" in body["capabilityIds"]


class Stage4Input(Input):
    name: str = ""


class Stage4Output(Output):
    message: str = "ok"

    @property
    def status_code(self) -> int:
        return 200


class Stage4UseCase(UseCase[Stage4Input, Stage4Output]):
    def __init__(self, inp: Stage4Input, events: list[str]) -> None:
        self._input = inp
        self._events = events

    @property
    def input(self) -> Stage4Input:
        return self._input

    def validate(self) -> str | None:
        self._events.append("validate")
        return None

    async def execute(self) -> Stage4Output:
        self._events.append("execute")
        return Stage4Output(message=f"Hello, {self.input.name}")


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


class ContextRoutePlugin(Plugin):
    manifest = PluginManifest(
        id="acme.context",
        display_name="Context Plugin",
        version="0.1.0",
        host_api_version=">=0.1.0 <0.2.0",
    )

    def setup(self, host: PluginHost) -> None:
        host.expose_capability(Capability(id="acme.capability", version="1.0.0", value=True))

        host.register_route(
            PluginRoute(
                id="plugin-context",
                method="POST",
                path="/plugin-context/{name}",
                visibility="custom",
                handler=lambda context: {
                    "status": 200,
                    "body": {
                        "requestId": context.request_id,
                        "loggerPresent": context.logger is not None,
                        "method": context.method,
                        "path": context.path,
                        "stageHeader": context.headers.get("x-stage4"),
                        "queryLang": context.query.get("lang"),
                        "bodyHello": (context.body or {}).get("hello"),
                        "pathName": context.path_params.get("name"),
                        "capabilityIds": list(context.capabilities().keys()),
                    },
                },
            )
        )


def logging_probe_middleware_definition(events: list[str]) -> PluginMiddleware:
    return PluginMiddleware(
        id="preRouting.logger",
        slot="preRouting",
        order=0,
        handler=make_recording_middleware(None, events, require_logger=True),
    )


def recording_middleware_definition(label: str, slot: str, order: int, events: list[str]) -> PluginMiddleware:
    return PluginMiddleware(
        id=label,
        slot=slot,
        order=order,
        handler=make_recording_middleware(label, events),
    )


def make_recording_middleware(
    label: str | None,
    events: list[str],
    *,
    require_logger: bool = False,
) -> type:
    class _RecordingMiddleware:
        def __init__(self, app: ASGIApp) -> None:
            self.app = app

        async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
            if scope["type"] != "http":
                await self.app(scope, receive, send)
                return

            request = Request(scope, receive, send)
            if require_logger:
                events.append(
                    "preRouting:logger"
                    if getattr(request.state, LOGGER_STATE_KEY, None) is not None
                    else "preRouting:no-logger"
                )
            elif label is not None:
                events.append(label)

            await self.app(scope, receive, send)

    return _RecordingMiddleware