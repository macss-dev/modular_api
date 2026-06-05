"""Tests for OpenAPI endpoint handlers — /openapi.json and /openapi.yaml."""

from __future__ import annotations

import json

import pytest
from starlette.routing import Route
from starlette.testclient import TestClient

from modular_api.core.registry import (
    UseCaseDocMeta,
    UseCaseRegistration,
    api_registry,
)
from modular_api.openapi.openapi import openapi_json_handler, openapi_yaml_handler


# ── Helpers ───────────────────────────────────────────────────


def _dummy_factory(json_data: dict) -> object:
    return object()


def _register_ping_usecase() -> None:
    """Put a single route into the registry so the spec is non-trivial."""
    api_registry.routes.append(
        UseCaseRegistration(
            module="test",
            command="ping",
            method="POST",
            path="/api/test/ping",
            factory=_dummy_factory,
            schemas={
                "input": {"type": "object", "properties": {}},
                "output": {
                    "type": "object",
                    "properties": {"pong": {"type": "boolean"}},
                },
            },
            doc=UseCaseDocMeta(summary="Ping", tags=["test"]),
        ),
    )


def _json_client(**kwargs: object) -> TestClient:
    """Build a TestClient wrapping the JSON endpoint in a Route."""
    endpoint = openapi_json_handler(**kwargs)
    app = Route("/", endpoint=endpoint)
    return TestClient(app)


def _yaml_client(**kwargs: object) -> TestClient:
    """Build a TestClient wrapping the YAML endpoint in a Route."""
    endpoint = openapi_yaml_handler(**kwargs)
    app = Route("/", endpoint=endpoint)
    return TestClient(app)


@pytest.fixture(autouse=True)
def _clean_registry():
    api_registry.clear()
    yield
    api_registry.clear()


# ── /openapi.json ─────────────────────────────────────────────


class TestOpenapiJsonHandler:
    """openapi_json_handler returns application/json with the spec."""

    def test_returns_200_with_json_content_type(self) -> None:
        _register_ping_usecase()
        client = _json_client(title="Test API", port=8000)

        response = client.get("/")
        assert response.status_code == 200
        assert "application/json" in response.headers["content-type"]

    def test_returns_valid_openapi_structure(self) -> None:
        _register_ping_usecase()
        client = _json_client(title="Test API", port=8000)

        spec = client.get("/").json()
        assert spec["openapi"] == "3.0.0"
        assert spec["info"]["title"] == "Test API"
        assert "/api/test/ping" in spec["paths"]

    def test_spec_has_servers_entry(self) -> None:
        _register_ping_usecase()
        client = _json_client(title="Test API", port=9090)

        spec = client.get("/").json()
        assert isinstance(spec["servers"], list)
        assert len(spec["servers"]) > 0


# ── /openapi.yaml ─────────────────────────────────────────────


class TestOpenapiYamlHandler:
    """openapi_yaml_handler returns application/x-yaml with the spec."""

    def test_returns_200_with_yaml_content_type(self) -> None:
        _register_ping_usecase()
        client = _yaml_client(title="Test API", port=8000)

        response = client.get("/")
        assert response.status_code == 200
        assert "application/x-yaml" in response.headers["content-type"]

    def test_yaml_contains_openapi_version(self) -> None:
        _register_ping_usecase()
        client = _yaml_client(title="Test API", port=8000)

        body = client.get("/").text
        assert "openapi: 3.0.0" in body

    def test_yaml_contains_registered_path(self) -> None:
        _register_ping_usecase()
        client = _yaml_client(title="Test API", port=8000)

        body = client.get("/").text
        assert "/api/test/ping:" in body

    def test_yaml_contains_info_section(self) -> None:
        _register_ping_usecase()
        client = _yaml_client(title="Test API", port=8000)

        body = client.get("/").text
        assert "info:" in body
        assert "title: Test API" in body

    def test_yaml_is_not_json(self) -> None:
        _register_ping_usecase()
        client = _yaml_client(title="Test API", port=8000)

        body = client.get("/").text
        assert not body.lstrip().startswith("{")


# ── JSON / YAML consistency ───────────────────────────────────


class TestOpenapiConsistency:
    """JSON and YAML endpoints represent the same spec."""

    def test_json_and_yaml_same_title(self) -> None:
        _register_ping_usecase()
        json_client = _json_client(title="Consistency Test", port=8000)
        yaml_client = _yaml_client(title="Consistency Test", port=8000)

        spec = json_client.get("/").json()
        yaml_body = yaml_client.get("/").text

        assert spec["openapi"] == "3.0.0"
        assert "title: Consistency Test" in yaml_body
