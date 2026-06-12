"""ADR-0003: plugin routes are first-class in OpenAPI and metrics."""

from __future__ import annotations

import re

from starlette.testclient import TestClient

from modular_api import (
    HOST_API_VERSION,
    ModularApi,
    Plugin,
    PluginHost,
    PluginManifest,
    PluginRoute,
    PluginValidationResult,
    RegisteredPluginRouteView,
)

_FOTO_OPERATION = {
    "summary": "Devuelve el binario de una foto",
    "parameters": [
        {"name": "nombre", "in": "query", "required": True, "schema": {"type": "string"}},
    ],
    "responses": {
        "200": {
            "description": "Foto encontrada",
            "content": {"image/jpeg": {"schema": {"type": "string", "format": "binary"}}},
        },
        "404": {"description": "Foto no encontrada"},
    },
}


class BinaryPlugin(Plugin):
    manifest = PluginManifest(
        id="test.binary",
        display_name="Test Binary Plugin",
        version="1.0.0",
        host_api_version=HOST_API_VERSION,
    )

    def setup(self, host: PluginHost) -> None:
        host.register_route(
            PluginRoute(
                id="binary.foto.get",
                method="GET",
                path="/binarios/foto",
                visibility="custom",
                handler=lambda _context: {
                    "status": 200,
                    "headers": {"content-type": "image/jpeg"},
                    "body": b"\xff\xd8\xff\xe0",
                },
                openapi=_FOTO_OPERATION,
            )
        )
        host.register_route(
            PluginRoute(
                id="binary.sin-doc.get",
                method="GET",
                path="/binarios/sin-doc",
                visibility="custom",
                handler=lambda _context: {"status": 200, "body": "ok"},
            )
        )


class ObserverPlugin(Plugin):
    manifest = PluginManifest(
        id="test.observer",
        display_name="Test Observer Plugin",
        version="1.0.0",
        host_api_version=HOST_API_VERSION,
    )

    def __init__(self) -> None:
        self.captured: list[RegisteredPluginRouteView] = []

    def setup(self, host: PluginHost) -> None:
        pass  # sin rutas

    def validate(self, host: PluginHost) -> list[PluginValidationResult]:
        self.captured = host.routes()
        return []


def test_documents_plugin_routes_that_declare_an_openapi_operation() -> None:
    api = ModularApi(base_path="/api", title="ADR3", version="1.0.0")
    api.plugin(BinaryPlugin())

    client = TestClient(api.build())
    spec = client.get("/api/openapi.json")
    assert spec.status_code == 200

    operation = spec.json()["paths"].get("/api/binarios/foto", {}).get("get")
    assert operation is not None
    assert operation["summary"] == "Devuelve el binario de una foto"
    assert operation["responses"]["200"]["content"]["image/jpeg"]["schema"]["format"] == "binary"


def test_does_not_document_routes_without_openapi_nor_operational_routes() -> None:
    api = ModularApi(base_path="/api", title="ADR3", version="1.0.0")
    api.plugin(BinaryPlugin())

    client = TestClient(api.build())
    spec = client.get("/api/openapi.json")
    assert spec.status_code == 200

    paths = spec.json().get("paths", {})
    assert "/api/binarios/sin-doc" not in paths
    assert "/api/health" not in paths
    assert "/api/openapi.json" not in paths


def test_exposes_registered_plugin_routes_through_the_host_routes_view() -> None:
    observer = ObserverPlugin()
    api = ModularApi(base_path="/api", title="ADR3", version="1.0.0")
    api.plugin(BinaryPlugin())
    api.plugin(observer)

    api.build()

    foto_route = next(
        (route for route in observer.captured if route.path == "/api/binarios/foto"),
        None,
    )
    assert foto_route is not None
    assert foto_route.plugin_id == "test.binary"
    assert foto_route.method == "GET"
    assert foto_route.visibility == "custom"
    assert foto_route.openapi is not None
    assert foto_route.openapi["summary"] == "Devuelve el binario de una foto"


def test_labels_plugin_routes_with_their_real_path_in_http_requests_total() -> None:
    api = ModularApi(
        base_path="/api",
        title="ADR3",
        version="1.0.0",
        metrics_enabled=True,
    )
    api.plugin(BinaryPlugin())

    client = TestClient(api.build())
    assert client.get("/api/binarios/foto").status_code == 200
    assert client.get("/api/binarios/foto").status_code == 200

    metrics = client.get("/api/metrics")
    assert metrics.status_code == 200
    assert 'route="/api/binarios/foto"' in metrics.text
    assert re.search(r'route="UNMATCHED"[^\n]*status_code="200"', metrics.text) is None
