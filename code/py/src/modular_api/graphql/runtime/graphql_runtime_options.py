"""GraphQL runtime options for Stage 6 integration."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Awaitable, Callable

from modular_api.graphql.catalog import GraphqlCatalog
from modular_api.graphql.read import ReadExecutor
from modular_api.graphql.schema import GraphqlSchemaSdlGenerator

graphql_default_read_executor_capability_id = "modular_api.sql.read_executor"


@dataclass(frozen=True, slots=True)
class GraphqlOptions:
    catalog_factory: Callable[[], Awaitable[GraphqlCatalog]]
    executor: ReadExecutor | None = None
    execution_capability_id: str | None = None
    introspection_enabled: bool = False
    max_depth: int = 8
    max_complexity: int = 500
    sdl_factory: Callable[[GraphqlCatalog], str] = GraphqlSchemaSdlGenerator().generate

    def __post_init__(self) -> None:
        if self.executor is not None and self.execution_capability_id is not None:
            raise ValueError(
                "GraphQL runtime accepts either a direct executor or an execution capability id, not both."
            )