from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from starlette.responses import HTMLResponse, JSONResponse, Response

from modular_api.core.health.health_service import HealthService
from modular_api.core.metrics.metric import Counter, Gauge, Histogram
from modular_api.core.metrics.metric_registry import MetricRegistry
from modular_api.core.metrics.metrics_middleware import metrics_middleware
from modular_api.core.plugin import Capability, Plugin, PluginHost, PluginManifest, PluginMiddleware, PluginRoute
from modular_api.openapi.openapi import build_openapi_spec, json_to_yaml
from modular_api.openapi.swagger_docs import build_swagger_docs_html

_OPENAPI_SPEC_CAPABILITY_ID = "modular_api.openapi.spec"
_OFFICIAL_PLUGIN_HOST_RANGE = ">=0.1.0 <0.2.0"


@dataclass(frozen=True)
class OperationalRoutePaths:
    health_path: str
    docs_path: str
    openapi_json_path: str
    openapi_yaml_path: str
    metrics_path: str | None = None


@dataclass(frozen=True)
class _OpenApiCapability:
    spec_url: str
    spec: dict[str, Any]
    yaml: str


def operational_route_paths(base_path: str, metrics_path: str | None = None) -> OperationalRoutePaths:
    return OperationalRoutePaths(
        health_path=_join_path(base_path, "/health"),
        docs_path=_join_path(base_path, "/docs"),
        openapi_json_path=_join_path(base_path, "/openapi.json"),
        openapi_yaml_path=_join_path(base_path, "/openapi.yaml"),
        metrics_path=None if metrics_path is None else _join_path(base_path, metrics_path),
    )


def build_runtime_plugins(
    *,
    base_path: str,
    title: str,
    version: str,
    port: int,
    health_service: HealthService,
    registered_paths: list[str],
    servers: list[dict[str, str]] | None = None,
    metric_registry: MetricRegistry | None = None,
    requests_total: Counter | None = None,
    requests_in_flight: Gauge | None = None,
    request_duration: Histogram | None = None,
    metrics_path: str | None = None,
) -> list[Plugin]:
    plugins: list[Plugin] = [_HealthRuntimePlugin(health_service)]

    if (
        metric_registry is not None
        and requests_total is not None
        and requests_in_flight is not None
        and request_duration is not None
        and metrics_path is not None
    ):
        plugins.append(
            _MetricsRuntimePlugin(
                base_path=base_path,
                metrics_path=metrics_path,
                registry=metric_registry,
                requests_total=requests_total,
                requests_in_flight=requests_in_flight,
                request_duration=request_duration,
                registered_paths=registered_paths,
            )
        )

    spec = build_openapi_spec(
        title=title,
        port=port,
        version=version,
        servers=servers,
    )
    spec_yaml = json_to_yaml(spec)

    plugins.append(_OpenApiRuntimePlugin(base_path=base_path, spec=spec, spec_yaml=spec_yaml))
    plugins.append(_DocsRuntimePlugin())
    return plugins


class _HealthRuntimePlugin(Plugin):
    def __init__(self, health_service: HealthService) -> None:
        self.manifest = PluginManifest(
            id="modular_api.health",
            display_name="Health Plugin",
            version="0.1.0",
            host_api_version=_OFFICIAL_PLUGIN_HOST_RANGE,
        )
        self._health_service = health_service

    def setup(self, host: PluginHost) -> None:
        async def _handler(context: Any) -> Response:
            health = await self._health_service.evaluate()
            return JSONResponse(
                content=health.to_json(),
                status_code=health.http_status_code,
                media_type="application/health+json",
            )

        host.register_route(
            PluginRoute(
                id="health.endpoint",
                method="GET",
                path="/health",
                visibility="operational",
                handler=_handler,
            )
        )


class _MetricsRuntimePlugin(Plugin):
    def __init__(
        self,
        *,
        base_path: str,
        metrics_path: str,
        registry: MetricRegistry,
        requests_total: Counter,
        requests_in_flight: Gauge,
        request_duration: Histogram,
        registered_paths: list[str],
    ) -> None:
        self.manifest = PluginManifest(
            id="modular_api.metrics",
            display_name="Metrics Plugin",
            version="0.1.0",
            host_api_version=_OFFICIAL_PLUGIN_HOST_RANGE,
        )
        self._base_path = base_path
        self._metrics_path = metrics_path
        self._registry = registry
        self._requests_total = requests_total
        self._requests_in_flight = requests_in_flight
        self._request_duration = request_duration
        self._registered_paths = registered_paths

    def setup(self, host: PluginHost) -> None:
        paths = operational_route_paths(self._base_path, self._metrics_path)
        excluded_routes = [
            paths.health_path,
            paths.docs_path,
            paths.openapi_json_path,
            paths.openapi_yaml_path,
        ]
        if paths.metrics_path is not None:
            excluded_routes.append(paths.metrics_path)

        host.register_middleware(
            PluginMiddleware(
                id="metrics.middleware",
                slot="preRouting",
                handler=metrics_middleware(
                    requests_total=self._requests_total,
                    requests_in_flight=self._requests_in_flight,
                    request_duration=self._request_duration,
                    excluded_routes=excluded_routes,
                    registered_paths=self._registered_paths,
                ),
            )
        )

        async def _handler(context: Any) -> Response:
            return Response(
                content=self._registry.serialize(),
                status_code=200,
                media_type="text/plain; version=0.0.4; charset=utf-8",
            )

        host.register_route(
            PluginRoute(
                id="metrics.endpoint",
                method="GET",
                path=self._metrics_path,
                visibility="operational",
                handler=_handler,
            )
        )


class _OpenApiRuntimePlugin(Plugin):
    def __init__(self, *, base_path: str, spec: dict[str, Any], spec_yaml: str) -> None:
        self.manifest = PluginManifest(
            id="modular_api.openapi",
            display_name="OpenAPI Plugin",
            version="0.1.0",
            host_api_version=_OFFICIAL_PLUGIN_HOST_RANGE,
        )
        self._base_path = base_path
        self._spec = spec
        self._spec_yaml = spec_yaml

    def setup(self, host: PluginHost) -> None:
        paths = operational_route_paths(self._base_path)
        host.expose_capability(
            Capability(
                id=_OPENAPI_SPEC_CAPABILITY_ID,
                version="1.0.0",
                value=_OpenApiCapability(
                    spec_url=paths.openapi_json_path,
                    spec=self._spec,
                    yaml=self._spec_yaml,
                ),
            )
        )

        async def _json_handler(context: Any) -> Response:
            return Response(
                content=json.dumps(self._spec, indent=2),
                status_code=200,
                media_type="application/json; charset=utf-8",
            )

        async def _yaml_handler(context: Any) -> Response:
            return Response(
                content=self._spec_yaml,
                status_code=200,
                media_type="application/x-yaml; charset=utf-8",
            )

        host.register_route(
            PluginRoute(
                id="openapi.json.endpoint",
                method="GET",
                path="/openapi.json",
                visibility="operational",
                handler=_json_handler,
            )
        )
        host.register_route(
            PluginRoute(
                id="openapi.yaml.endpoint",
                method="GET",
                path="/openapi.yaml",
                visibility="operational",
                handler=_yaml_handler,
            )
        )


class _DocsRuntimePlugin(Plugin):
    def __init__(self) -> None:
        self.manifest = PluginManifest(
            id="modular_api.docs",
            display_name="Docs Plugin",
            version="0.1.0",
            host_api_version=_OFFICIAL_PLUGIN_HOST_RANGE,
        )

    def setup(self, host: PluginHost) -> None:
        capability = host.require_capability(_OPENAPI_SPEC_CAPABILITY_ID)
        openapi_spec = capability.value
        html = build_swagger_docs_html(
            title=host.metadata().title,
            spec_url=openapi_spec.spec_url,
        )

        async def _handler(context: Any) -> Response:
            return HTMLResponse(html)

        host.register_route(
            PluginRoute(
                id="docs.endpoint",
                method="GET",
                path="/docs",
                visibility="operational",
                handler=_handler,
            )
        )


def _normalize_base_path(base_path: str) -> str:
    if not base_path or base_path == "/":
        return "/"
    return "/" + base_path.strip().strip("/")


def _normalize_relative_path(path: str) -> str:
    trimmed = path.strip()
    if not trimmed:
        raise ValueError("Plugin route path cannot be empty")
    return "/" + trimmed.strip("/")


def _join_path(base_path: str, relative_path: str) -> str:
    normalized_base_path = _normalize_base_path(base_path)
    normalized_relative_path = _normalize_relative_path(relative_path)
    if normalized_base_path == "/":
        return normalized_relative_path
    return f"{normalized_base_path}{normalized_relative_path}".replace("//", "/")