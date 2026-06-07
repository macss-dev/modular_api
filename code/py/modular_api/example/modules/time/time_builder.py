from __future__ import annotations

from modular_api import ModuleBuilder

from .usecases.current_time import CurrentTime


def build_time_module(m: ModuleBuilder) -> None:
    m.usecase("current-time", CurrentTime.from_json, method="GET")
