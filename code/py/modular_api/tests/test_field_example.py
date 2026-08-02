"""Tests for example values in OpenAPI schema — Python SDK.

Verifies _normalize_schema converts Pydantic examples → OpenAPI 3.0.3 example,
and composes a top-level example from per-field values.
"""

from __future__ import annotations

from typing import Any, cast

from pydantic import Field

from modular_api.core.usecase import Input, Output


# `to_schema()` returns `dict[str, object]` — a generated JSON Schema is arbitrary nested JSON, and the
# public signature says so rather than promising a shape it cannot check. These two readers are where
# this test states the shape it expects, once, instead of at every assertion.
def _properties(schema: dict[str, object]) -> dict[str, Any]:
    return cast("dict[str, Any]", schema["properties"])


def _required(schema: dict[str, object]) -> list[str]:
    return cast("list[str]", schema.get("required", []))


# ── DTOs with example values ──────────────────────────────────


class ExampleInput(Input):
    name: str = Field(description="User name", examples=["Alice"])
    age: int = Field(description="User age", examples=[30])
    score: float = Field(description="Score", examples=[9.5])
    active: bool = Field(description="Active?", examples=[True])
    tags: list[str] = Field(description="Tags", examples=[["dart", "ts"]])


class ExampleOutput(Output):
    greeting: str = Field(description="Greeting", examples=["Hello Alice"])

    @property
    def status_code(self) -> int:
        return 200


class NoExampleInput(Input):
    name: str = Field(description="Just a name")


# ── Tests ──────────────────────────────────────────────────────


class TestFieldExampleMetadata:
    """Verify per-property example values in schema."""

    def test_string_field_example(self) -> None:
        schema = ExampleInput.to_schema()
        props = _properties(schema)
        assert props["name"]["example"] == "Alice"

    def test_integer_field_example(self) -> None:
        schema = ExampleInput.to_schema()
        props = _properties(schema)
        assert props["age"]["example"] == 30

    def test_number_field_example(self) -> None:
        schema = ExampleInput.to_schema()
        props = _properties(schema)
        assert props["score"]["example"] == 9.5

    def test_boolean_field_example(self) -> None:
        schema = ExampleInput.to_schema()
        props = _properties(schema)
        assert props["active"]["example"] is True

    def test_array_field_example(self) -> None:
        schema = ExampleInput.to_schema()
        props = _properties(schema)
        assert props["tags"]["example"] == ["dart", "ts"]


class TestTopLevelExample:
    """Verify top-level example object in schema."""

    def test_top_level_example(self) -> None:
        schema = ExampleInput.to_schema()
        assert schema["example"] == {
            "name": "Alice",
            "age": 30,
            "score": 9.5,
            "active": True,
            "tags": ["dart", "ts"],
        }

    def test_output_top_level_example(self) -> None:
        schema = ExampleOutput.to_schema()
        assert schema["example"] == {"greeting": "Hello Alice"}

    def test_no_example_omits_key(self) -> None:
        schema = NoExampleInput.to_schema()
        props = _properties(schema)
        assert "example" not in props["name"]
        assert "example" not in schema
