"""Tests for build_openapi_spec — generates OpenAPI 3.0 from api_registry."""

from __future__ import annotations

import pytest

from modular_api.core.registry import (
    ApiRegistry,
    UseCaseDocMeta,
    UseCaseRegistration,
    api_registry,
)
from modular_api.openapi.openapi import build_openapi_spec


# ── Helpers ───────────────────────────────────────────────────


def _dummy_factory(json: dict) -> object:
    return object()


def _make_registration(**overrides: object) -> UseCaseRegistration:
    defaults: dict = {
        "module": "users",
        "command": "create",
        "method": "POST",
        "path": "/api/users/create",
        "factory": _dummy_factory,
        "schemas": {
            "input": {
                "type": "object",
                "properties": {"name": {"type": "string"}},
                "required": ["name"],
            },
            "output": {
                "type": "object",
                "properties": {"id": {"type": "integer"}},
            },
        },
        "doc": UseCaseDocMeta(
            summary="Create a user",
            description="Creates a new user in the system",
            tags=["users"],
        ),
    }
    defaults.update(overrides)
    return UseCaseRegistration(**defaults)


@pytest.fixture(autouse=True)
def _clean_registry():
    api_registry.clear()
    yield
    api_registry.clear()


# ── Top-level structure ───────────────────────────────────────


class TestOpenApiStructure:
    """build_openapi_spec produces a valid OpenAPI 3.0 skeleton."""

    def test_openapi_version(self) -> None:
        spec = build_openapi_spec(title="Test API", port=8000)
        assert spec["openapi"] == "3.0.0"

    def test_info_section(self) -> None:
        spec = build_openapi_spec(title="Test API", port=8000, version="2.0.0")
        info = spec["info"]
        assert info["title"] == "Test API"
        assert info["version"] == "2.0.0"

    def test_default_version(self) -> None:
        spec = build_openapi_spec(title="Test API", port=8000)
        assert spec["info"]["version"] == "0.1.0"

    def test_default_server(self) -> None:
        spec = build_openapi_spec(title="Test API", port=9090)
        servers = spec["servers"]
        assert len(servers) == 1
        assert servers[0]["url"] == "http://localhost:9090"

    def test_custom_servers(self) -> None:
        custom = [{"url": "https://prod.example.com", "description": "Production"}]
        spec = build_openapi_spec(title="Test API", port=8000, servers=custom)
        assert spec["servers"] == custom

    def test_paths_key_exists(self) -> None:
        spec = build_openapi_spec(title="Test API", port=8000)
        assert "paths" in spec

    def test_empty_registry_produces_empty_paths(self) -> None:
        spec = build_openapi_spec(title="Test API", port=8000)
        assert spec["paths"] == {}


# ── POST use case → requestBody ───────────────────────────────


class TestOpenApiPostUseCase:
    """POST use cases produce requestBody with the Input schema."""

    def test_post_has_request_body(self) -> None:
        api_registry.routes.append(_make_registration())
        spec = build_openapi_spec(title="Test", port=8000)

        operation = spec["paths"]["/api/users/create"]["post"]
        assert "requestBody" in operation

    def test_request_body_references_input_schema(self) -> None:
        api_registry.routes.append(_make_registration())
        spec = build_openapi_spec(title="Test", port=8000)

        operation = spec["paths"]["/api/users/create"]["post"]
        schema_ref = operation["requestBody"]["content"]["application/json"]["schema"]
        assert schema_ref == {"$ref": "#/components/schemas/users_create_Input"}

    def test_components_include_input_schema(self) -> None:
        api_registry.routes.append(_make_registration())
        spec = build_openapi_spec(title="Test", port=8000)

        schemas = spec["components"]["schemas"]
        assert "users_create_Input" in schemas
        assert schemas["users_create_Input"]["type"] == "object"

    def test_components_include_output_schema(self) -> None:
        api_registry.routes.append(_make_registration())
        spec = build_openapi_spec(title="Test", port=8000)

        schemas = spec["components"]["schemas"]
        assert "users_create_Output" in schemas
        assert schemas["users_create_Output"]["type"] == "object"


# ── GET use case → query parameters ──────────────────────────


class TestOpenApiGetUseCase:
    """GET use cases produce query parameters from the Input schema."""

    def test_get_has_parameters(self) -> None:
        api_registry.routes.append(
            _make_registration(command="list", method="GET", path="/api/users/list"),
        )
        spec = build_openapi_spec(title="Test", port=8000)

        operation = spec["paths"]["/api/users/list"]["get"]
        assert "parameters" in operation
        assert "requestBody" not in operation

    def test_query_params_from_input_properties(self) -> None:
        api_registry.routes.append(
            _make_registration(command="list", method="GET", path="/api/users/list"),
        )
        spec = build_openapi_spec(title="Test", port=8000)

        params = spec["paths"]["/api/users/list"]["get"]["parameters"]
        name_param = next(p for p in params if p["name"] == "name")
        assert name_param["in"] == "query"
        assert name_param["required"] is True
        assert name_param["schema"] == {"type": "string"}


# ── Responses ─────────────────────────────────────────────────


class TestOpenApiResponses:
    """Every operation has 200, 400, and 500 responses."""

    def test_standard_responses_present(self) -> None:
        api_registry.routes.append(_make_registration())
        spec = build_openapi_spec(title="Test", port=8000)

        responses = spec["paths"]["/api/users/create"]["post"]["responses"]
        assert "200" in responses
        assert "400" in responses
        assert "500" in responses

    def test_200_references_output_schema(self) -> None:
        api_registry.routes.append(_make_registration())
        spec = build_openapi_spec(title="Test", port=8000)

        resp_200 = spec["paths"]["/api/users/create"]["post"]["responses"]["200"]
        schema = resp_200["content"]["application/json"]["schema"]
        assert schema == {"$ref": "#/components/schemas/users_create_Output"}


# ── Operation metadata ────────────────────────────────────────


class TestOpenApiOperationMetadata:
    """operationId, tags, and summary come from the registration."""

    def test_operation_id(self) -> None:
        api_registry.routes.append(_make_registration())
        spec = build_openapi_spec(title="Test", port=8000)

        operation = spec["paths"]["/api/users/create"]["post"]
        assert operation["operationId"] == "users_create_post"

    def test_tags_from_doc(self) -> None:
        api_registry.routes.append(_make_registration())
        spec = build_openapi_spec(title="Test", port=8000)

        operation = spec["paths"]["/api/users/create"]["post"]
        assert operation["tags"] == ["users"]

    def test_summary_from_doc(self) -> None:
        api_registry.routes.append(_make_registration())
        spec = build_openapi_spec(title="Test", port=8000)

        operation = spec["paths"]["/api/users/create"]["post"]
        assert operation["summary"] == "Create a user"

    def test_description_from_doc(self) -> None:
        api_registry.routes.append(_make_registration())
        spec = build_openapi_spec(title="Test", port=8000)

        operation = spec["paths"]["/api/users/create"]["post"]
        assert operation["description"] == "Creates a new user in the system"


# ── Multiple routes on the same path ─────────────────────────


class TestMultipleMethodsOnSamePath:
    """Two use cases on the same path produce both methods."""

    def test_same_path_different_methods(self) -> None:
        api_registry.routes.append(
            _make_registration(command="item", method="GET", path="/api/users/item"),
        )
        api_registry.routes.append(
            _make_registration(command="item", method="PUT", path="/api/users/item"),
        )
        spec = build_openapi_spec(title="Test", port=8000)

        path_obj = spec["paths"]["/api/users/item"]
        assert "get" in path_obj
        assert "put" in path_obj
