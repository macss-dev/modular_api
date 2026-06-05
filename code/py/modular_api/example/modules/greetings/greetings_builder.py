from __future__ import annotations

from modular_api import ModuleBuilder

from .usecases.hello_world import HelloWorld


def build_greetings_module(m: ModuleBuilder) -> None:
    m.usecase("hello-world", HelloWorld.from_json)
