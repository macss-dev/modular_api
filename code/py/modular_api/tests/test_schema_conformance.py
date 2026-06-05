"""Conformance tests: HelloWorldInput/HelloWorldOutput schemas match shared fixtures."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import sys

from pydantic import Field

_EXAMPLE_DIR = Path(__file__).resolve().parent.parent / "example"
sys.path.insert(0, str(_EXAMPLE_DIR))

from modules.greetings.usecases.hello_world import HelloWorldInput, HelloWorldOutput  # type: ignore[import-untyped]

from modular_api.core.usecase import Input

_FIXTURES = Path(__file__).resolve().parents[3] / "tests" / "fixtures"


def _load_fixture(name: str) -> dict[str, object]:
    return json.loads((_FIXTURES / name).read_text(encoding="utf-8"))


class TestSchemaConformance:
    """Verify our example DTOs produce schemas identical to the shared fixtures."""

    def test_hello_input_schema_matches_fixture(self) -> None:
        fixture = _load_fixture("hello_input_schema.json")
        # to_schema() is now a classmethod — call on class, not instance
        assert HelloWorldInput.to_schema() == fixture

    def test_hello_output_schema_matches_fixture(self) -> None:
        fixture = _load_fixture("hello_output_schema.json")
        assert HelloWorldOutput.to_schema() == fixture

    def test_hello_input_from_json(self) -> None:
        """from_json populates fields correctly."""
        instance = HelloWorldInput.from_json({"name": "Carlos"})
        assert instance.name == "Carlos"

    def test_hello_input_to_json(self) -> None:
        """to_json serializes correctly."""
        instance = HelloWorldInput(name="Carlos")
        assert instance.to_json() == {"name": "Carlos"}

    def test_hello_output_from_json(self) -> None:
        instance = HelloWorldOutput.from_json({"message": "Hello!"})
        assert instance.message == "Hello!"

    def test_hello_output_to_json(self) -> None:
        instance = HelloWorldOutput(message="Hello!")
        assert instance.to_json() == {"message": "Hello!"}


class WebhookInput(Input):
    instruction_id: str = Field(description="Payment instruction ID", examples=["20260323ABC"])
    transfer_details: dict[str, Any] = Field(description="Nested transfer info", examples=[{"amount": 2300, "currency": "PEN"}])


class TestSchemaConformanceObjectType:
    """Verify dict[str, Any] produces a schema identical to the shared fixture."""

    def test_webhook_input_schema_matches_fixture(self) -> None:
        fixture = _load_fixture("webhook_input_schema.json")
        assert WebhookInput.to_schema() == fixture
