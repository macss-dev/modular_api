"""Core contracts: UseCase, Input, Output.

Lifecycle (handled by the framework):
  1. ``from_json(json)``    — static factory, builds the use case
  2. ``validate()``         — return error string or ``None``
  3. ``execute()``          — run business logic, set output
  4. ``output.to_json()``   — serialize and return to HTTP client
"""

from __future__ import annotations

import warnings
from abc import ABC, abstractmethod
from typing import Any, Generic, TypeVar

from pydantic import BaseModel


def _reorder_type_first(prop: dict[str, Any]) -> dict[str, Any]:
    """Ensure ``type`` is the first key — matches Dart/TS property order."""
    if "type" not in prop:
        return prop
    return {"type": prop["type"], **{k: v for k, v in prop.items() if k != "type"}}


def _normalize_schema(raw: dict[str, Any]) -> dict[str, object]:
    """Normalize Pydantic JSON Schema (Draft 2020-12) to OpenAPI 3.0.3.

    Pydantic's ``model_json_schema()`` emits Draft 2020-12 constructs
    (``anyOf``, ``$defs``, ``title``) that OpenAPI 3.0.3 does not support.
    This function rewrites them into the ``nullable`` / ``required`` pattern.
    """
    props: dict[str, Any] = raw.get("properties", {})
    required: list[str] = list(raw.get("required", []))
    normalized_props: dict[str, Any] = {}

    for name, prop in props.items():
        # Pydantic emits {"anyOf": [{"type":"string"}, {"type":"null"}]}
        # for Optional fields. Collapse to {"type":"string","nullable":true}
        # and remove the field from required[].
        if "anyOf" in prop:
            non_null = [v for v in prop["anyOf"] if v != {"type": "null"}]
            if len(non_null) == 1:
                collapsed = dict(non_null[0])
                collapsed["nullable"] = True
                # Preserve description if present on the outer property
                if "description" in prop:
                    collapsed["description"] = prop["description"]
                # Convert examples → example (nullable fields)
                if "examples" in prop and prop["examples"]:
                    collapsed["example"] = prop["examples"][0]
                collapsed.pop("additionalProperties", None)
                normalized_props[name] = _reorder_type_first(collapsed)
                if name in required:
                    required.remove(name)
                continue

        # Strip Pydantic's auto-generated ``title``, ``default``, and
        # ``additionalProperties`` (emitted for dict[str, Any] fields) from properties.
        cleaned = {k: v for k, v in prop.items() if k not in ("title", "default", "additionalProperties")}

        # Convert Pydantic ``examples`` (list, Draft 2020-12) → OpenAPI ``example`` (singular)
        if "examples" in cleaned and cleaned["examples"]:
            cleaned["example"] = cleaned["examples"][0]
            del cleaned["examples"]

        normalized_props[name] = _reorder_type_first(cleaned)

    # Compose top-level example from per-field examples
    example_values: dict[str, Any] = {}
    for name, prop in normalized_props.items():
        if "example" in prop:
            example_values[name] = prop["example"]

    result: dict[str, object] = {"type": "object", "properties": normalized_props}
    if required:
        result["required"] = required
    if example_values:
        result["example"] = example_values
    return result


class Input(BaseModel):
    """Contract for use-case input DTOs.

    Inherits from Pydantic ``BaseModel``. Subclasses declare typed fields
    and get ``from_json``, ``to_json``, and ``to_schema`` automatically.
    Manual overrides still work (deprecated — will be removed in v0.5.0).

    Equivalent in Dart:  ``class HelloInput implements Input { ... }``
    Equivalent in TS:    ``class HelloInput extends Input { ... }``
    """

    model_config = {"extra": "ignore"}

    def __init_subclass__(cls, **kwargs: object) -> None:
        super().__init_subclass__(**kwargs)
        if "to_schema" in cls.__dict__:
            warnings.warn(
                f"{cls.__name__}.to_schema() is deprecated. "
                "Remove it — schema is derived automatically from field declarations.",
                DeprecationWarning,
                stacklevel=2,
            )

    @classmethod
    def from_json(cls, json: dict[str, object]) -> Input:
        """Deserialize from a plain dict with strict type validation.

        Uses Pydantic strict mode so JSON types must match field declarations
        exactly — no implicit coercion (e.g. int → str is rejected).
        Raises ``ValidationError`` for missing or wrongly-typed fields.
        """
        return cls.model_validate(json, strict=True)

    def to_json(self) -> dict[str, object]:
        """Serialize to a plain dict."""
        return self.model_dump()

    @classmethod
    def to_schema(cls) -> dict[str, object]:
        """Return an OpenAPI 3.0.3-compatible JSON Schema for this Input."""
        return _normalize_schema(cls.model_json_schema())


class Output(BaseModel):
    """Contract for use-case output DTOs.

    Inherits from Pydantic ``BaseModel``. The implementor must define
    ``status_code`` explicitly — this forces developers to think about
    HTTP status codes for every response.

    Equivalent in Dart:  ``class HelloOutput implements Output { ... }``
    Equivalent in TS:    ``class HelloOutput extends Output { ... }``
    """

    model_config = {"extra": "ignore"}

    def __init_subclass__(cls, **kwargs: object) -> None:
        super().__init_subclass__(**kwargs)
        if "to_schema" in cls.__dict__:
            warnings.warn(
                f"{cls.__name__}.to_schema() is deprecated. "
                "Remove it — schema is derived automatically from field declarations.",
                DeprecationWarning,
                stacklevel=2,
            )

    @classmethod
    def from_json(cls, json: dict[str, object]) -> Output:
        """Deserialize from a plain dict with strict type validation."""
        return cls.model_validate(json, strict=True)

    def to_json(self) -> dict[str, object]:
        """Serialize to a plain dict."""
        return self.model_dump()

    @classmethod
    def to_schema(cls) -> dict[str, object]:
        """Return an OpenAPI 3.0.3-compatible JSON Schema for this Output."""
        return _normalize_schema(cls.model_json_schema())

    @property
    @abstractmethod
    def status_code(self) -> int:
        """HTTP status code to return (e.g. 200, 201, 400, 404)."""
        ...


I = TypeVar("I", bound=Input)
O = TypeVar("O", bound=Output)


class UseCase(ABC, Generic[I, O]):
    """Contract for business logic units.

    Lifecycle (handled by the framework):
      1. ``from_json(json)``    — static factory, builds the use case
      2. ``validate()``         — return error string or ``None``
      3. ``execute()``          — run business logic, return Output
      4. handler serializes     — ``output.to_json()`` → HTTP response
    """

    # Request-scoped logger injected by the framework before execute().
    # Available inside execute(). None when running without middleware.
    logger: object | None = None

    @property
    @abstractmethod
    def input(self) -> I:
        """Input DTO — set in constructor."""
        ...

    @abstractmethod
    def validate(self) -> str | None:
        """Validate the input. Return an error message or ``None``."""
        ...

    @abstractmethod
    async def execute(self) -> O:
        """Run the business logic and return the Output."""
        ...
