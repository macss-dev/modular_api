"""GraphQL runtime plugin for Stage 6 startup integration."""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Any

from modular_api.core.health.health_check import HealthCheck, HealthCheckResult, HealthStatus
from modular_api.core.health.health_service import HealthService
from modular_api.core.plugin import Plugin, PluginHost, PluginManifest, PluginRequestContext, PluginValidationResult
from modular_api.graphql.catalog import GraphqlCatalog
from modular_api.graphql.read import ReadExecutor
from modular_api.graphql.runtime.graphql_runtime_options import (
    GraphqlOptions,
    graphql_default_read_executor_capability_id,
)

_OFFICIAL_PLUGIN_HOST_RANGE = ">=0.1.0 <0.2.0"


@dataclass(slots=True)
class _GraphqlRuntimeState:
    status: str = "disabled"
    catalog: GraphqlCatalog | None = None
    executor: ReadExecutor | None = None
    sdl: str | None = None


class GraphqlRuntimePlugin(Plugin):
    def __init__(self, *, options: GraphqlOptions | None, health_service: HealthService) -> None:
        self.manifest = PluginManifest(
            id="modular_api.graphql",
            display_name="GraphQL Plugin",
            version="0.1.0",
            host_api_version=_OFFICIAL_PLUGIN_HOST_RANGE,
        )
        self._options = options
        self._health_service = health_service
        self._state = _GraphqlRuntimeState()

    def setup(self, host: PluginHost) -> None:
        self._health_service.add_health_check(_GraphqlRuntimeHealthCheck(self._state))

        if self._options is None:
            return

        async def _handler(context: PluginRequestContext) -> dict[str, object]:
            query = _read_query(context.body)
            if query is None:
                return {
                    "status": 400,
                    "body": {
                        "errors": [{"message": "GraphQL request body must include a query string."}],
                    },
                }
            if "__typename" in query:
                return {"status": 200, "body": {"data": {"__typename": "Query"}}}
            return {
                "status": 400,
                "body": {
                    "errors": [{"message": "Stage 6 runtime only supports the __typename readiness probe."}],
                },
            }

        host.register_route(
            {
                "id": "graphql.endpoint",
                "method": "POST",
                "path": "/graphql",
                "visibility": "transport",
                "handler": _handler,
            }
        )

    def validate(self, host: PluginHost) -> list[PluginValidationResult]:
        if self._options is None:
            return []

        if self._options.max_depth < 1:
            return [self._validation_failure("graphql.maxDepth", "GraphQL max_depth must be greater than or equal to 1.")]

        if self._options.max_complexity < 1:
            return [
                self._validation_failure(
                    "graphql.maxComplexity",
                    "GraphQL max_complexity must be greater than or equal to 1.",
                )
            ]

        executor = self._options.executor
        if executor is None:
            capability_id = self._options.execution_capability_id or graphql_default_read_executor_capability_id
            capability = host.resolve_capability(capability_id)
            if capability is None:
                return [
                    self._validation_failure(
                        capability_id,
                        f"Missing GraphQL read executor capability: {capability_id}",
                    )
                ]
            if not _is_read_executor(capability.value):
                return [
                    self._validation_failure(
                        capability_id,
                        f"Capability {capability_id} does not expose a ReadExecutor.",
                    )
                ]
            executor = capability.value

        try:
            catalog = asyncio.run(self._options.catalog_factory())
        except Exception as error:  # noqa: BLE001
            return [
                self._validation_failure(
                    "graphql.catalog",
                    f"GraphQL catalog construction failed: {error}",
                )
            ]

        try:
            sdl = self._options.sdl_factory(catalog)
            _validate_generated_sdl(sdl)
        except Exception as error:  # noqa: BLE001
            return [
                self._validation_failure(
                    "graphql.schema",
                    f"GraphQL schema generation failed: {error}",
                )
            ]

        self._state.status = "ready"
        self._state.catalog = catalog
        self._state.executor = executor
        self._state.sdl = sdl
        return []

    def _validation_failure(self, resource_id: str, message: str) -> PluginValidationResult:
        return PluginValidationResult(
            code="PLUGIN_VALIDATION_FAILED",
            message=message,
            plugin_id=self.manifest.id,
            resource_id=resource_id,
        )


class _GraphqlRuntimeHealthCheck(HealthCheck):
    def __init__(self, state: _GraphqlRuntimeState) -> None:
        self._state = state

    @property
    def name(self) -> str:
        return "graphql"

    async def check(self) -> HealthCheckResult:
        output = "disabled" if self._state.status == "disabled" else "ready"
        return HealthCheckResult(status=HealthStatus.PASS, output=output)


def _read_query(body: Any) -> str | None:
    if not isinstance(body, dict):
        return None
    query = body.get("query")
    return query if isinstance(query, str) else None


def _is_read_executor(value: Any) -> bool:
    return hasattr(value, "execute") and callable(value.execute)


def _validate_generated_sdl(sdl: str) -> None:
    if not sdl.strip():
        raise ValueError("Generated SDL must not be empty.")
    if "type Query {" not in sdl:
        raise ValueError("Generated SDL must declare a Query root type.")

    depth = 0
    for char in sdl:
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth < 0:
                raise ValueError("Generated SDL has unmatched closing brace.")
    if depth != 0:
        raise ValueError("Generated SDL has unmatched opening brace.")