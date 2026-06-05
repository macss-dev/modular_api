"""RED — fromJson must validate required fields and types, returning 400.

fromJson validates structure (field presence + JSON type correctness).
validate() handles only business rules.

Error message contract (identical across all 3 SDKs for parity):
  - Missing required field: "Missing required field: {name}"
  - Wrong JSON type:        "Field '{name}' must be of type {type}"
"""

import json
from typing import Any

import pytest
from pydantic import Field, ValidationError
from starlette.applications import Starlette
from starlette.routing import Route
from starlette.testclient import TestClient

from modular_api.core.usecase import Input, Output, UseCase
from modular_api.core.usecase_handler import usecase_handler


# ── Stubs ─────────────────────────────────────────────────────────────────


class StrictInput(Input):
    name: str = Field(description="Name")
    age: int = Field(description="Age")


class StrictOutput(Output):
    greeting: str = ""

    @property
    def status_code(self) -> int:
        return 200


class StrictUseCase(UseCase[StrictInput, StrictOutput]):
    """Minimal use case with strict string + int fields."""

    def __init__(self, data: dict) -> None:
        self._input = StrictInput.from_json(data)

    @property
    def input(self) -> StrictInput:
        return self._input

    def validate(self) -> str | None:
        if not self.input.name:
            return "name is required"
        return None

    async def execute(self) -> StrictOutput:
        return StrictOutput(greeting=f"Hi {self.input.name}, age {self.input.age}")


def _app():
    return Starlette(routes=[
        Route("/strict", usecase_handler(StrictUseCase), methods=["POST"]),
    ])


# ── Unit: from_json strict type validation ────────────────────────────────


class TestFromJsonStrictValidation:
    """from_json rejects missing fields and wrong JSON types."""

    def test_missing_required_field_raises_validation_error(self) -> None:
        with pytest.raises(ValidationError):
            StrictInput.from_json({})

    def test_wrong_type_for_string_field_raises_validation_error(self) -> None:
        """Sending int where str expected must fail in strict mode."""
        with pytest.raises(ValidationError):
            StrictInput.from_json({"name": 123, "age": 25})

    def test_wrong_type_for_int_field_raises_validation_error(self) -> None:
        """Sending str where int expected must fail in strict mode."""
        with pytest.raises(ValidationError):
            StrictInput.from_json({"name": "Alice", "age": "twenty-five"})

    def test_valid_json_succeeds(self) -> None:
        result = StrictInput.from_json({"name": "Alice", "age": 25})
        assert result.name == "Alice"
        assert result.age == 25


# ── Integration: handler returns 400 with specific error messages ─────────


class TestFromJsonHandlerErrors:
    """Handler returns 400 with field-specific error messages."""

    def test_missing_field_returns_400_with_field_name(self) -> None:
        client = TestClient(_app())
        resp = client.post("/strict", json={})
        assert resp.status_code == 400
        body = resp.json()
        assert body["error"] == "Missing required field: name"

    def test_wrong_type_returns_400_with_expected_type(self) -> None:
        client = TestClient(_app())
        resp = client.post("/strict", json={"name": 123, "age": 25})
        assert resp.status_code == 400
        body = resp.json()
        assert body["error"] == "Field 'name' must be of type string"

    def test_wrong_int_type_returns_400_with_expected_type(self) -> None:
        client = TestClient(_app())
        resp = client.post("/strict", json={"name": "Alice", "age": "not-a-number"})
        assert resp.status_code == 400
        body = resp.json()
        assert body["error"] == "Field 'age' must be of type integer"

    def test_valid_json_returns_200(self) -> None:
        client = TestClient(_app())
        resp = client.post("/strict", json={"name": "Alice", "age": 25})
        assert resp.status_code == 200
        body = resp.json()
        assert body["greeting"] == "Hi Alice, age 25"


# ── Unit: dict[str, Any] object type validation ──────────────────────────


class ObjectInput(Input):
    id: str = Field(description="ID")
    details: dict[str, Any] = Field(description="Nested object")


class TestFromJsonObjectType:
    """Pydantic strict mode validates dict[str, Any] as object type."""

    def test_accepts_dict_for_object_field(self) -> None:
        result = ObjectInput.from_json({"id": "abc", "details": {"amount": 100}})
        assert result.id == "abc"
        assert result.details == {"amount": 100}

    def test_rejects_string_for_object_field(self) -> None:
        with pytest.raises(ValidationError):
            ObjectInput.from_json({"id": "abc", "details": "not-a-dict"})

    def test_rejects_list_for_object_field(self) -> None:
        with pytest.raises(ValidationError):
            ObjectInput.from_json({"id": "abc", "details": [1, 2]})
