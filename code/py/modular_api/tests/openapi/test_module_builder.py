"""Tests for ModuleBuilder — fluent builder that registers use cases on a Starlette Router."""

from __future__ import annotations

from abc import ABC

import pytest

from modular_api.core.module_builder import ModuleBuilder
from modular_api.core.registry import ApiRegistry, api_registry
from modular_api.core.usecase import Input, Output, UseCase


# ── Minimal UseCase for registration tests ────────────────────


class _StubInput(Input):
    name: str = ""


class _StubOutput(Output):
    ok: bool = True

    @property
    def status_code(self) -> int:
        return 200


class _StubUseCase(UseCase[_StubInput, _StubOutput]):
    """Stub where output is available immediately (no execute() needed).

    This mirrors the Dart/TS pattern where toSchema() is callable
    right after construction — the schema is static metadata,
    not runtime state.
    """

    def __init__(self, inp: _StubInput) -> None:
        self._input = inp

    @property
    def input(self) -> _StubInput:
        return self._input

    def validate(self) -> str | None:
        return None

    async def execute(self) -> _StubOutput:
        return _StubOutput()

    @staticmethod
    def from_json(json: dict) -> _StubUseCase:
        return _StubUseCase(_StubInput())


# ── Tests ─────────────────────────────────────────────────────


@pytest.fixture(autouse=True)
def _clean_registry():
    """Ensure global registry is empty before and after each test."""
    api_registry.clear()
    yield
    api_registry.clear()


class TestModuleBuilderRegistration:
    """usecase() registers routes in the global api_registry."""

    def test_registers_route_in_api_registry(self) -> None:
        builder = ModuleBuilder(base_path="/api", module_name="users")
        builder.usecase("create", _StubUseCase.from_json)

        assert len(api_registry.routes) == 1
        reg = api_registry.routes[0]
        assert reg.module == "users"
        assert reg.command == "create"

    def test_default_method_is_post(self) -> None:
        builder = ModuleBuilder(base_path="/api", module_name="users")
        builder.usecase("create", _StubUseCase.from_json)

        assert api_registry.routes[0].method == "POST"

    def test_path_is_base_module_name(self) -> None:
        builder = ModuleBuilder(base_path="/api", module_name="users")
        builder.usecase("create", _StubUseCase.from_json)

        assert api_registry.routes[0].path == "/api/users/create"

    def test_strips_leading_slash_from_usecase_name(self) -> None:
        builder = ModuleBuilder(base_path="/api", module_name="users")
        builder.usecase("/create", _StubUseCase.from_json)

        reg = api_registry.routes[0]
        assert reg.command == "create"
        assert reg.path == "/api/users/create"

    def test_strips_whitespace_from_usecase_name(self) -> None:
        builder = ModuleBuilder(base_path="/api", module_name="users")
        builder.usecase("  create  ", _StubUseCase.from_json)

        reg = api_registry.routes[0]
        assert reg.command == "create"

    def test_method_override_get(self) -> None:
        builder = ModuleBuilder(base_path="/api", module_name="users")
        builder.usecase("list", _StubUseCase.from_json, method="GET")

        assert api_registry.routes[0].method == "GET"

    def test_method_override_put(self) -> None:
        builder = ModuleBuilder(base_path="/api", module_name="users")
        builder.usecase("update", _StubUseCase.from_json, method="PUT")

        assert api_registry.routes[0].method == "PUT"

    def test_method_override_patch(self) -> None:
        builder = ModuleBuilder(base_path="/api", module_name="users")
        builder.usecase("partial", _StubUseCase.from_json, method="PATCH")

        assert api_registry.routes[0].method == "PATCH"

    def test_method_override_delete(self) -> None:
        builder = ModuleBuilder(base_path="/api", module_name="users")
        builder.usecase("remove", _StubUseCase.from_json, method="DELETE")

        assert api_registry.routes[0].method == "DELETE"


class TestModuleBuilderDocMetadata:
    """summary, description, and tags are stored in the registration."""

    def test_default_doc_metadata(self) -> None:
        builder = ModuleBuilder(base_path="/api", module_name="users")
        builder.usecase("create", _StubUseCase.from_json)

        doc = api_registry.routes[0].doc
        assert doc is not None
        assert "create" in doc.summary
        assert "users" in doc.summary
        assert doc.tags == ["users"]

    def test_custom_summary_and_description(self) -> None:
        builder = ModuleBuilder(base_path="/api", module_name="users")
        builder.usecase(
            "create",
            _StubUseCase.from_json,
            summary="Create a user",
            description="Creates a new user in the system",
        )

        doc = api_registry.routes[0].doc
        assert doc is not None
        assert doc.summary == "Create a user"
        assert doc.description == "Creates a new user in the system"


class TestModuleBuilderSchemaExtraction:
    """Schemas are captured from a dummy factory call at registration time."""

    def test_captures_input_schema(self) -> None:
        builder = ModuleBuilder(base_path="/api", module_name="users")
        builder.usecase("create", _StubUseCase.from_json)

        schemas = api_registry.routes[0].schemas
        assert schemas["input"] == {"type": "object", "properties": {"name": {"type": "string"}}}

    def test_captures_output_schema(self) -> None:
        builder = ModuleBuilder(base_path="/api", module_name="users")
        builder.usecase("create", _StubUseCase.from_json)

        schemas = api_registry.routes[0].schemas
        assert schemas["output"] == {"type": "object", "properties": {"ok": {"type": "boolean"}}}

    def test_fallback_when_factory_raises(self) -> None:
        """Class-level extraction works even when factory raises."""

        def exploding_factory(json: dict) -> _StubUseCase:
            raise RuntimeError("cannot build from empty json")

        builder = ModuleBuilder(base_path="/api", module_name="users")
        builder.usecase("create", exploding_factory)

        schemas = api_registry.routes[0].schemas
        # Strategy 1 (class-level) resolves schemas from the return type hint,
        # so the factory never needs to be instantiated.
        assert schemas["input"] == {"type": "object", "properties": {"name": {"type": "string"}}}
        assert schemas["output"] == {"type": "object", "properties": {"ok": {"type": "boolean"}}}


class TestModuleBuilderFluent:
    """usecase() returns self for method chaining."""

    def test_chaining_multiple_usecases(self) -> None:
        builder = ModuleBuilder(base_path="/api", module_name="users")
        result = builder.usecase("create", _StubUseCase.from_json).usecase("list", _StubUseCase.from_json, method="GET")

        assert result is builder
        assert len(api_registry.routes) == 2


class TestModuleBuilderBasePathNormalization:
    """base_path without leading slash is normalized."""

    def test_base_path_without_leading_slash(self) -> None:
        builder = ModuleBuilder(base_path="api", module_name="users")
        builder.usecase("create", _StubUseCase.from_json)

        assert api_registry.routes[0].path == "/api/users/create"

    def test_empty_base_path(self) -> None:
        builder = ModuleBuilder(base_path="", module_name="users")
        builder.usecase("create", _StubUseCase.from_json)

        assert api_registry.routes[0].path == "/users/create"
