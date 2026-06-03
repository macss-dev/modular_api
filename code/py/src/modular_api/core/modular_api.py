"""Main orchestrator — wires modules, middleware, health, metrics, and OpenAPI.

Mirror of ``ModularApi`` in Dart and TypeScript.

Usage::

    from modular_api import ModularApi

    api = ModularApi(base_path="/api", title="My API")
    api.module("users", lambda m: (
        m.usecase("create", CreateUser.from_json),
        m.usecase("list", ListUsers.from_json, method="GET"),
    ))
    api.add_health_check(DatabaseHealthCheck())

    # Build the ASGI app (for testing or custom entrypoint)
    app = api.build()

    # Or start directly with Uvicorn
    api.serve(port=8080)
"""

from __future__ import annotations

from contextlib import asynccontextmanager
from typing import Any, Callable

from starlette.applications import Starlette
from starlette.routing import Mount, Route, Router

from modular_api.core.health.health_check import HealthCheck
from modular_api.core.error_response_middleware import error_response_middleware
from modular_api.core.health.health_service import HealthService
from modular_api.core.logger.logger import LogLevel
from modular_api.core.logger.logging_middleware import logging_middleware
from modular_api.core.metrics.metric import Counter, Gauge, Histogram
from modular_api.core.metrics.metric_registry import MetricRegistry, MetricsRegistrar
from modular_api.core.module_builder import ModuleBuilder
from modular_api.core.official_plugins import build_runtime_plugins, operational_route_paths
from modular_api.core.plugin import Plugin, PluginHostError, RuntimePluginHost, order_plugins
from modular_api.core.registry import api_registry
from modular_api.graphql.runtime import GraphqlOptions


class ModularApi:
    """Assembles modules, middleware, health, metrics, and docs into a Starlette app.

    Provides a fluent builder API — every configuration method returns ``self``
    so calls can be chained.
    """

    def __init__(
        self,
        *,
        base_path: str = "/api",
        title: str = "Modular API",
        version: str = "0.0.0",
        release_id: str | None = None,
        servers: list[dict[str, str]] | None = None,
        metrics_enabled: bool = False,
        metrics_path: str = "/metrics",
        log_level: LogLevel = LogLevel.info,
        graphql: GraphqlOptions | None = None,
    ) -> None:
        self._base_path = base_path
        self._title = title
        self._version = version
        self._release_id = release_id or f"{version}-debug"
        self._servers = servers
        self._metrics_enabled = metrics_enabled
        self._metrics_path = metrics_path
        self._log_level = log_level
        self._graphql = graphql

        self._health_service = HealthService(version=version, release_id=self._release_id)
        self._module_routers: list[tuple[str, Router]] = []
        self._custom_middlewares: list[type] = []
        self._plugins: list[Plugin] = []

        # Metrics infrastructure (only when enabled)
        self._metric_registry: MetricRegistry | None = None
        self._metrics_registrar: MetricsRegistrar | None = None
        self._http_requests_total: Counter | None = None
        self._http_requests_in_flight: Gauge | None = None
        self._http_request_duration: Histogram | None = None
        if metrics_enabled:
            self._metric_registry = MetricRegistry()
            self._metrics_registrar = MetricsRegistrar(self._metric_registry)
            self._http_requests_total = self._metric_registry.create_counter(
                name="http_requests_total",
                help="Total number of HTTP requests.",
            )
            self._http_requests_in_flight = self._metric_registry.create_gauge(
                name="http_requests_in_flight",
                help="Number of HTTP requests currently being processed.",
            )
            self._http_request_duration = self._metric_registry.create_histogram(
                name="http_request_duration_seconds",
                help="HTTP request duration in seconds.",
            )

    # ── Public properties ─────────────────────────────────────

    @property
    def title(self) -> str:
        return self._title

    @property
    def version(self) -> str:
        return self._version

    @property
    def metrics(self) -> MetricsRegistrar | None:
        """Return the MetricsRegistrar for custom metric creation, or None when disabled."""
        return self._metrics_registrar

    # ── Fluent configuration API ──────────────────────────────

    def module(self, name: str, build: Callable[[ModuleBuilder], Any]) -> ModularApi:
        """Register a group of use cases under a named module."""
        builder = ModuleBuilder(base_path=self._base_path, module_name=name)
        build(builder)
        mount_path = f"{self._normalize_base(self._base_path)}/{name}"
        self._module_routers.append((mount_path, builder.build_router()))
        return self

    def use(self, middleware_factory: Any) -> ModularApi:
        """Add a custom ASGI middleware class (or factory returning one)."""
        self._custom_middlewares.append(middleware_factory)
        return self

    def plugin(self, plugin: Plugin) -> ModularApi:
        """Register a plugin instance for this API."""
        self._plugins.append(plugin)
        return self

    def add_health_check(self, check: HealthCheck) -> ModularApi:
        """Register a HealthCheck to be evaluated on GET /health."""
        self._health_service.add_health_check(check)
        return self

    # ── Application assembly ──────────────────────────────────

    def build(self, *, port: int = 8000) -> Starlette:
        """Assemble and return the Starlette ASGI application.

        Auto-mounts /health, /openapi.json, /openapi.yaml, and
        (when metrics are enabled) the metrics endpoint.
        """
        operational_paths = operational_route_paths(
            self._base_path,
            self._metrics_path if self._metrics_enabled else None,
        )
        runtime_plugins = [
            *self._plugins,
            *build_runtime_plugins(
                base_path=self._base_path,
                title=self._title,
                version=self._version,
                port=port,
                health_service=self._health_service,
                graphql=self._graphql,
                registered_paths=[route.path for route in api_registry.routes],
                servers=self._servers,
                metric_registry=self._metric_registry,
                requests_total=self._http_requests_total,
                requests_in_flight=self._http_requests_in_flight,
                request_duration=self._http_request_duration,
                metrics_path=self._metrics_path if self._metrics_enabled else None,
            ),
        ]

        seen_plugin_ids: set[str] = set()
        for plugin in runtime_plugins:
            if plugin.manifest.id in seen_plugin_ids:
                raise PluginHostError(
                    "PLUGIN_ID_CONFLICT",
                    f"Duplicate plugin id: {plugin.manifest.id}",
                    resource_id=plugin.manifest.id,
                )
            seen_plugin_ids.add(plugin.manifest.id)

        ordered_plugins = order_plugins(runtime_plugins)

        plugin_host = RuntimePluginHost(
            base_path=self._base_path,
            title=self._title,
            version=self._version,
        )
        try:
            for plugin in ordered_plugins:
                plugin_host.begin_plugin_setup(plugin.manifest.id)
                try:
                    plugin.setup(plugin_host)
                finally:
                    plugin_host.end_plugin_setup()
                plugin_host.on_shutdown(plugin.shutdown)
            plugin_host.freeze()
            validation_results = []
            for plugin in ordered_plugins:
                validation_results.extend(plugin.validate(plugin_host))
            plugin_host.assert_valid(validation_results)
        except Exception:
            plugin_host.shutdown_sync()
            raise

        routes = self._collect_routes()
        routes.extend(plugin_host.build_routes())

        @asynccontextmanager
        async def lifespan(_: Starlette):
            try:
                yield
            finally:
                await plugin_host.shutdown()

        app = Starlette(routes=routes, lifespan=lifespan)

        # Middleware pipeline (LIFO — last added is outermost)
        # 1. postHandler middlewares (innermost wrapper before the route app)
        for middleware in reversed(plugin_host.middlewares_for_slot("postHandler")):
            app.add_middleware(middleware.handler)

        # 2. preHandler middlewares
        for middleware in reversed(plugin_host.middlewares_for_slot("preHandler")):
            app.add_middleware(middleware.handler)

        # 3. Custom middlewares
        for mw in reversed(self._custom_middlewares):
            app.add_middleware(mw)

        # 4. preRouting middlewares (wrap custom + routes)
        for middleware in reversed(plugin_host.middlewares_for_slot("preRouting")):
            app.add_middleware(middleware.handler)

        # 4b. Error normalization middleware (wraps plugin middleware + routes)
        app.add_middleware(error_response_middleware())

        # 5. Logging middleware (outermost — wraps everything)
        excluded_log_routes = [
            operational_paths.health_path,
            operational_paths.docs_path,
            operational_paths.openapi_json_path,
            operational_paths.openapi_yaml_path,
        ]
        if operational_paths.metrics_path is not None:
            excluded_log_routes.append(operational_paths.metrics_path)
        app.add_middleware(
            logging_middleware(
                log_level=self._log_level,
                service_name=self._title,
                excluded_routes=excluded_log_routes,
            ),
        )

        return app

    def serve(self, *, port: int = 8000, host: str = "0.0.0.0") -> None:
        """Start the server with Uvicorn (blocking call)."""
        import uvicorn  # noqa: PLC0415 — lazy import, only needed at runtime

        app = self.build(port=port)
        uvicorn.run(app, host=host, port=port)

    # ── Private helpers ───────────────────────────────────────

    def _collect_routes(self) -> list[Route | Mount]:
        """Collect all module routes."""
        routes: list[Route | Mount] = []

        # Module use-case routes
        for mount_path, router in self._module_routers:
            routes.append(Mount(mount_path, app=router))

        return routes

    @staticmethod
    def _normalize_base(path: str) -> str:
        if not path:
            return ""
        return path if path.startswith("/") else f"/{path}"
