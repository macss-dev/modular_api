from __future__ import annotations

from starlette.testclient import TestClient

from modular_api import ModularApi


def test_operational_endpoints_resolve_under_shared_base_path() -> None:
    api = ModularApi(
        base_path="/api",
        title="Plugin Ops",
        version="1.0.0",
        metrics_enabled=True,
    )

    client = TestClient(api.build())

    health = client.get("/api/health")
    assert health.status_code == 200
    assert health.json()["status"] == "pass"

    metrics = client.get("/api/metrics")
    assert metrics.status_code == 200
    assert "http_requests_total" in metrics.text

    openapi_json = client.get("/api/openapi.json")
    assert openapi_json.status_code == 200
    assert openapi_json.json()["openapi"] == "3.0.0"

    openapi_yaml = client.get("/api/openapi.yaml")
    assert openapi_yaml.status_code == 200
    assert "openapi: 3.0.0" in openapi_yaml.text

    docs = client.get("/api/docs")
    assert docs.status_code == 200
    assert "/api/openapi.json" in docs.text

    assert client.get("/health").status_code == 404
    assert client.get("/metrics").status_code == 404
    assert client.get("/openapi.json").status_code == 404
    assert client.get("/openapi.yaml").status_code == 404
    assert client.get("/docs").status_code == 404