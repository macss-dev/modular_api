"""``from_json`` must hand back the subclass it was called on, not the base contract.

**It did not.** ``Input.from_json`` and ``Output.from_json`` were annotated ``-> Input`` / ``-> Output``,
so for every consumer DTO the inherited factory was declared to return the base class:

    class CuentaInput(Input):
        cuenta_id: str

    parsed = CuentaInput.from_json(payload)   # declared: Input
    parsed.cuenta_id                          # error: unknown attribute on "Input"

The value at runtime was always the subclass — ``cls.model_validate`` builds ``cls`` — so nothing
misbehaved. What broke was every consumer's type checker, which had to be silenced with a cast on each
call to reach the fields the DTO exists to carry. This is the same shape of defect as annotating a
TypeScript constructor parameter ``unknown[]``: the safe-looking base type in a position that needs the
polymorphic one.

These tests are checked twice over, and the static half is the point:

- ``assert_type`` is a no-op at runtime and an *error at type-check time* when the declared type differs,
  so reverting ``Self`` to ``Input`` makes pyright fail here even though pytest still passes.
- the attribute reads below only type-check if the ``assert_type`` above them holds, which is what a
  consumer actually does with the result.

Mirror of ``usecase_class_types.test.ts``, which guards the equivalent TypeScript signature.
"""

from __future__ import annotations

from typing import assert_type

from modular_api.core.usecase import Input, Output


class _ProbeInput(Input):
    name: str


class _ProbeOutput(Output):
    greeting: str = ""

    @property
    def status_code(self) -> int:
        return 200


def test_input_from_json_returns_the_subclass() -> None:
    parsed = _ProbeInput.from_json({"name": "socia"})

    assert_type(parsed, _ProbeInput)
    assert parsed.name == "socia"
    assert isinstance(parsed, _ProbeInput)


def test_output_from_json_returns_the_subclass() -> None:
    parsed = _ProbeOutput.from_json({"greeting": "hola"})

    assert_type(parsed, _ProbeOutput)
    assert parsed.greeting == "hola"
    assert isinstance(parsed, _ProbeOutput)


def test_the_base_classes_still_declare_the_factory() -> None:
    # `Self` is not a way of dropping the contract: both base classes still publish `from_json`, which is
    # what the framework's handler calls without knowing the concrete DTO.
    assert callable(Input.from_json)
    assert callable(Output.from_json)
