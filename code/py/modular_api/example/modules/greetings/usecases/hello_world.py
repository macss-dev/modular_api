from __future__ import annotations

from modular_api import Input, Output, UseCase, Field


# ── Input DTO ─────────────────────────────────────────────────


class HelloWorldInput(Input):
    name: str = Field(description="Name to greet", examples=["World"])


# ── Output DTO ────────────────────────────────────────────────


class HelloWorldOutput(Output):
    message: str = Field(description="Greeting message", examples=["Hello, World!"])

    @property
    def status_code(self) -> int:
        return 200


# ── UseCase ───────────────────────────────────────────────────


class HelloWorld(UseCase[HelloWorldInput, HelloWorldOutput]):
    def __init__(self, input_dto: HelloWorldInput) -> None:
        self._input = input_dto

    @property
    def input(self) -> HelloWorldInput:
        return self._input

    @classmethod
    def from_json(cls, json: dict[str, object]) -> HelloWorld:
        return cls(HelloWorldInput.from_json(json))

    def validate(self) -> str | None:
        if not self.input.name:
            return "name is required"
        return None

    async def execute(self) -> HelloWorldOutput:
        self.logger.info(f"Greeting user: {self.input.name}")
        return HelloWorldOutput(message=f"Hello, {self.input.name}!")
