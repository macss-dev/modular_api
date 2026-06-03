"""GraphQL runtime options for Stage 6 integration."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Awaitable, Callable, TypeAlias

from modular_api.graphql.catalog import GraphqlCatalog
from modular_api.graphql.read import ReadExecutor
from modular_api.graphql.schema import GraphqlSchemaSdlGenerator

graphql_default_read_executor_capability_id = "modular_api.sql.read_executor"


class GraphqlRequestPhase(str, Enum):
    STARTED = "started"
    COMPLETED = "completed"

    def __str__(self) -> str:
        return self.value


@dataclass(frozen=True, slots=True)
class GraphqlRequestEvent:
    phase: GraphqlRequestPhase
    request_id: str
    method: str
    path: str
    status_code: int | None = None


GraphqlEventSink: TypeAlias = Callable[[GraphqlRequestEvent], Awaitable[None] | None]
GraphqlSourceDigestFactory: TypeAlias = Callable[[], Awaitable[str] | str]


@dataclass(frozen=True, slots=True)
class GraphqlOptions:
    catalog_factory: Callable[[], Awaitable[GraphqlCatalog]]
    executor: ReadExecutor | None = None
    execution_capability_id: str | None = None
    introspection_enabled: bool = False
    max_depth: int = 8
    max_complexity: int = 500
    default_limit: int = 50
    max_limit: int = 200
    on_event: GraphqlEventSink | None = None
    artifact_directory: str | None = None
    source_digest_factory: GraphqlSourceDigestFactory | None = None
    sdl_factory: Callable[[GraphqlCatalog], str] = GraphqlSchemaSdlGenerator().generate

    def __post_init__(self) -> None:
        if self.executor is not None and self.execution_capability_id is not None:
            raise ValueError(
                "GraphQL runtime accepts either a direct executor or an execution capability id, not both."
            )

    @property
    def resolved_execution_capability_id(self) -> str:
        return self.execution_capability_id or graphql_default_read_executor_capability_id