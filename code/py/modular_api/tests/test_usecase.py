"""Tests for UseCase, Input, Output core contracts."""

from __future__ import annotations

import pytest

from modular_api.core.usecase import Input, Output, UseCase


# ── Concrete stubs for testing ──────────────────────────────────────


class SumInput(Input):
    """Two integers to sum."""

    a: int | None = None
    b: int | None = None


class SumOutput(Output):
    """Result of the sum operation."""

    resultado: int = 0

    @property
    def status_code(self) -> int:
        return 200


class SumUseCase(UseCase[SumInput, SumOutput]):
    """Sums two integers."""

    def __init__(self, input_dto: SumInput) -> None:
        self._input = input_dto

    @property
    def input(self) -> SumInput:
        return self._input

    def validate(self) -> str | None:
        if self._input.a is None:
            return "a is required"
        if self._input.b is None:
            return "b is required"
        return None

    async def execute(self) -> SumOutput:
        a = self._input.a or 0
        b = self._input.b or 0
        return SumOutput(resultado=a + b)


# ── Input tests ─────────────────────────────────────────────────────


class TestInput:
    def test_bare_input_is_instantiable(self) -> None:
        """Input with no fields can be instantiated (it's a BaseModel now)."""
        instance = Input()
        assert instance.to_json() == {}

    def test_concrete_input_to_json(self) -> None:
        inp = SumInput(a=3, b=4)
        assert inp.to_json() == {"a": 3, "b": 4}

    def test_concrete_input_to_schema(self) -> None:
        schema = SumInput.to_schema()
        assert schema["type"] == "object"
        assert "a" in schema["properties"]  # type: ignore[operator]


# ── Output tests ────────────────────────────────────────────────────


class TestOutput:
    def test_cannot_instantiate_without_status_code(self) -> None:
        """Output requires status_code — subclass must define it."""
        with pytest.raises(TypeError):
            Output()  # type: ignore[abstract]

    def test_concrete_output_to_json(self) -> None:
        out = SumOutput(resultado=7)
        assert out.to_json() == {"resultado": 7}

    def test_concrete_output_to_schema(self) -> None:
        schema = SumOutput.to_schema()
        assert schema["type"] == "object"
        assert "resultado" in schema["properties"]  # type: ignore[operator]

    def test_concrete_output_status_code(self) -> None:
        out = SumOutput(resultado=0)
        assert out.status_code == 200


# ── UseCase tests ───────────────────────────────────────────────────


class TestUseCase:
    def test_cannot_instantiate_directly(self) -> None:
        with pytest.raises(TypeError):
            UseCase()  # type: ignore[abstract]

    def test_validate_returns_none_when_valid(self) -> None:
        uc = SumUseCase(SumInput(a=3, b=4))
        assert uc.validate() is None

    def test_validate_returns_error_when_invalid(self) -> None:
        uc = SumUseCase(SumInput(a=5, b=None))
        assert uc.validate() is not None

    async def test_execute_returns_output(self) -> None:
        uc = SumUseCase(SumInput(a=3, b=4))
        assert uc.validate() is None
        output = await uc.execute()
        assert output.resultado == 7

    async def test_execute_output_serializes(self) -> None:
        uc = SumUseCase(SumInput(a=10, b=20))
        output = await uc.execute()
        assert output.to_json() == {"resultado": 30}

    def test_logger_defaults_to_none(self) -> None:
        uc = SumUseCase(SumInput(a=1, b=2))
        assert uc.logger is None
