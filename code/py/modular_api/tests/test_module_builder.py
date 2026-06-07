"""Tests for ModuleBuilder schema extraction.

Verifies that _extract_schemas captures Input and Output schemas
independently — a failure in Output (e.g. uninitialized property)
must not destroy the already-computable Input schema.
"""

from __future__ import annotations

from pydantic import Field

from modular_api.core.module_builder import ModuleBuilder
from modular_api.core.registry import api_registry
from modular_api.core.usecase import Input, Output, UseCase


# ── Stubs: Using new BaseModel-based DTOs ─────────────────────


class StubInput(Input):
    name: str = Field(description="Name to greet")


class StubOutput(Output):
    message: str = Field(description="Greeting message")

    @property
    def status_code(self) -> int:
        return 200


class StubUseCase(UseCase[StubInput, StubOutput]):
    """UseCase with BaseModel-based DTOs."""

    def __init__(self, input_dto: StubInput) -> None:
        self._input = input_dto

    @property
    def input(self) -> StubInput:
        return self._input

    @classmethod
    def from_json(cls, json: dict) -> StubUseCase:
        return cls(StubInput.from_json(json))

    def validate(self) -> str | None:
        if not self.input.name:
            return "name is required"
        return None

    async def execute(self) -> StubOutput:
        return StubOutput(message=f"Hello, {self.input.name}!")


# ── Tests ─────────────────────────────────────────────────────────────────


class TestExtractSchemas:
    """Schema extraction must capture Input and Output independently."""

    def setup_method(self) -> None:
        api_registry.clear()

    def teardown_method(self) -> None:
        api_registry.clear()

    def test_input_schema_has_properties(self) -> None:
        schemas = ModuleBuilder._extract_schemas(StubUseCase.from_json)
        assert "name" in schemas["input"].get("properties", {}), (
            "Input schema lost its properties"
        )

    def test_output_schema_has_properties(self) -> None:
        schemas = ModuleBuilder._extract_schemas(StubUseCase.from_json)
        assert "message" in schemas["output"].get("properties", {}), (
            "Output schema must have properties.message"
        )

    def test_input_schema_name_type_is_string(self) -> None:
        schemas = ModuleBuilder._extract_schemas(StubUseCase.from_json)
        name_prop = schemas["input"]["properties"]["name"]  # type: ignore[index]
        assert name_prop["type"] == "string"

    def test_output_schema_message_type_is_string(self) -> None:
        schemas = ModuleBuilder._extract_schemas(StubUseCase.from_json)
        msg_prop = schemas["output"]["properties"]["message"]  # type: ignore[index]
        assert msg_prop["type"] == "string"
