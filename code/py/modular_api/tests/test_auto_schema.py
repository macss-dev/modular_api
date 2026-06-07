"""Tests for auto-schema: Input and Output as BaseModel subclasses."""

from __future__ import annotations

import warnings

from pydantic import BaseModel, Field

from modular_api.core.usecase import Input, Output


class TestInputIsBaseModel:
    """Input must inherit from BaseModel so Pydantic drives serialization."""

    def test_input_is_subclass_of_basemodel(self) -> None:
        assert issubclass(Input, BaseModel)

    def test_input_has_to_json(self) -> None:
        assert hasattr(Input, "to_json")

    def test_input_has_to_schema(self) -> None:
        assert hasattr(Input, "to_schema")

    def test_input_has_from_json(self) -> None:
        assert hasattr(Input, "from_json")

    def test_simple_input_auto_schema(self) -> None:
        """A minimal Input subclass derives its schema from field declarations."""

        class NameInput(Input):
            name: str = Field(description="Name to greet")

        schema = NameInput.to_schema()
        assert schema["type"] == "object"
        assert "name" in schema["properties"]
        assert schema["properties"]["name"]["type"] == "string"
        assert schema["properties"]["name"]["description"] == "Name to greet"
        assert "name" in schema["required"]

    def test_simple_input_from_json(self) -> None:
        """from_json() builds an Input instance from a plain dict."""

        class NameInput(Input):
            name: str

        instance = NameInput.from_json({"name": "Carlos"})
        assert instance.name == "Carlos"

    def test_simple_input_to_json(self) -> None:
        """to_json() serializes an Input to a plain dict."""

        class NameInput(Input):
            name: str

        instance = NameInput(name="Carlos")
        result = instance.to_json()
        assert result == {"name": "Carlos"}

    def test_optional_field_schema(self) -> None:
        """Optional fields are excluded from required[] and marked nullable."""

        class OptInput(Input):
            required_field: str
            optional_field: str | None = None

        schema = OptInput.to_schema()
        assert "required_field" in schema["required"]
        # optional_field should NOT be in required
        assert "optional_field" not in schema.get("required", [])


class TestManualToSchemaDeprecation:
    """Overriding to_schema() should emit a DeprecationWarning."""

    def test_manual_to_schema_on_input_emits_warning(self) -> None:
        with warnings.catch_warnings(record=True) as w:
            warnings.simplefilter("always")

            class LegacyInput(Input):
                name: str

                @classmethod
                def to_schema(cls) -> dict[str, object]:
                    return {"type": "object"}

            assert len(w) == 1
            assert issubclass(w[0].category, DeprecationWarning)
            assert "LegacyInput.to_schema()" in str(w[0].message)

    def test_manual_to_schema_on_output_emits_warning(self) -> None:
        with warnings.catch_warnings(record=True) as w:
            warnings.simplefilter("always")

            class LegacyOutput(Output):
                message: str

                @property
                def status_code(self) -> int:
                    return 200

                @classmethod
                def to_schema(cls) -> dict[str, object]:
                    return {"type": "object"}

            assert len(w) == 1
            assert issubclass(w[0].category, DeprecationWarning)
            assert "LegacyOutput.to_schema()" in str(w[0].message)

    def test_no_warning_without_override(self) -> None:
        with warnings.catch_warnings(record=True) as w:
            warnings.simplefilter("always")

            class CleanInput(Input):
                name: str

        assert len(w) == 0
