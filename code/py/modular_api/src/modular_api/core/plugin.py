"""Public plugin-host contract and minimal runtime host for modular_api."""

from __future__ import annotations

import asyncio
import inspect
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any, Callable

from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse, Response
from starlette.routing import Route
from starlette.types import ASGIApp, Receive, Scope, Send

from modular_api.core.logger.logging_middleware import LOGGER_STATE_KEY
from modular_api.core.logger.logger import ModularLogger, RequestScopedLogger
from modular_api.core.request_pipeline_audit import (
    ShortCircuitAuditEntry,
    clear_short_circuit_candidate,
    set_short_circuit_candidate,
)
from modular_api.core.registry import api_registry

HOST_API_VERSION = "0.1.0"
_ALLOWED_MIDDLEWARE_SLOTS = {"preRouting", "preHandler", "postHandler"}


@dataclass(frozen=True)
class PluginRequirement:
    type: str
    id: str
    version: str | None = None


@dataclass(frozen=True)
class PluginManifest:
    id: str
    display_name: str
    version: str
    host_api_version: str
    requires: list[PluginRequirement] = field(default_factory=list)
    optional: list[PluginRequirement] = field(default_factory=list)
    contributes: dict[str, Any] | None = None


@dataclass(frozen=True)
class HostMetadata:
    base_path: str
    title: str
    version: str
    host_api_version: str


@dataclass(frozen=True)
class PluginValidationResult:
    code: str
    message: str
    plugin_id: str | None = None
    resource_id: str | None = None
    blocking: bool = True


@dataclass(frozen=True)
class Capability:
    id: str
    version: str
    value: Any


CapabilityHandle = Capability


@dataclass(frozen=True)
class ModuleExtensionPoint:
    id: str
    mode: str
    description: str | None = None


@dataclass(frozen=True)
class ModuleExtensionContribution:
    extension_point_id: str
    module_name: str
    value: Any


@dataclass(frozen=True)
class RegisteredModuleView:
    name: str


@dataclass(frozen=True)
class RegisteredUseCaseView:
    module: str
    command: str
    method: str
    path: str


@dataclass(frozen=True)
class PluginRequestContext:
    request_id: str
    logger: ModularLogger | None
    method: str
    path: str
    headers: dict[str, str]
    query: dict[str, str]
    body: Any
    path_params: dict[str, str]
    capabilities: Callable[[], dict[str, CapabilityHandle]]


@dataclass(frozen=True)
class PluginRoute:
    id: str
    method: str
    path: str
    visibility: str
    handler: Callable[[PluginRequestContext], Any]
    # Optional standard OpenAPI Operation object (summary, parameters, requestBody,
    # responses — including binary content types). When present on a `custom` or
    # `transport` route, the official OpenApiPlugin merges it into the generated
    # spec so the route appears in /openapi.json and /docs (ADR-0003).
    openapi: dict[str, Any] | None = None


@dataclass(frozen=True)
class RegisteredPluginRouteView:
    """Read view of a plugin route already registered on the host (ADR-0003)."""

    id: str
    method: str
    # Absolute mounted path (base_path already joined).
    path: str
    visibility: str
    plugin_id: str | None = None
    openapi: dict[str, Any] | None = None


@dataclass(frozen=True)
class PluginMiddleware:
    id: str
    slot: str
    handler: Any
    order: int = 0


class PluginHostError(Exception):
    def __init__(
        self,
        code: str,
        message: str,
        *,
        plugin_id: str | None = None,
        resource_id: str | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.plugin_id = plugin_id
        self.resource_id = resource_id


class PluginHost(ABC):
    @abstractmethod
    def metadata(self) -> HostMetadata:
        raise NotImplementedError

    @abstractmethod
    def modules(self) -> list[RegisteredModuleView]:
        raise NotImplementedError

    @abstractmethod
    def usecases(self) -> list[RegisteredUseCaseView]:
        raise NotImplementedError

    @abstractmethod
    def routes(self) -> list[RegisteredPluginRouteView]:
        raise NotImplementedError

    @abstractmethod
    def register_route(self, route: PluginRoute) -> None:
        raise NotImplementedError

    @abstractmethod
    def register_middleware(self, middleware: PluginMiddleware) -> None:
        raise NotImplementedError

    @abstractmethod
    def expose_capability(self, capability: Capability) -> None:
        raise NotImplementedError

    @abstractmethod
    def resolve_capability(self, capability_id: str) -> CapabilityHandle | None:
        raise NotImplementedError

    @abstractmethod
    def require_capability(self, capability_id: str) -> CapabilityHandle:
        raise NotImplementedError

    @abstractmethod
    def declare_module_extension_point(self, point: ModuleExtensionPoint) -> None:
        raise NotImplementedError

    @abstractmethod
    def contribute_module_extension(self, contribution: ModuleExtensionContribution) -> None:
        raise NotImplementedError

    @abstractmethod
    def add_startup_validation(self, validation: PluginValidationResult) -> None:
        raise NotImplementedError

    @abstractmethod
    def on_shutdown(self, callback: Callable[[], Any]) -> None:
        raise NotImplementedError


class Plugin(ABC):
    manifest: PluginManifest

    @abstractmethod
    def setup(self, host: PluginHost) -> None:
        raise NotImplementedError

    def validate(self, host: PluginHost) -> list[PluginValidationResult]:
        return []

    async def shutdown(self) -> None:
        return None


def order_plugins(plugins: list[Plugin]) -> list[Plugin]:
    plugins_by_id = {plugin.manifest.id: plugin for plugin in plugins}
    visit_state: dict[str, str] = {}
    ordered: list[Plugin] = []

    def visit(plugin: Plugin) -> None:
        plugin_id = plugin.manifest.id
        state = visit_state.get(plugin_id)
        if state == "visited":
            return

        if state == "visiting":
            raise PluginHostError(
                "PLUGIN_DEPENDENCY_CYCLE",
                f"Plugin dependency cycle detected at {plugin_id}",
                plugin_id=plugin_id,
                resource_id=plugin_id,
            )

        visit_state[plugin_id] = "visiting"
        for requirement in plugin.manifest.requires:
            if requirement.type != "plugin":
                continue

            dependency = plugins_by_id.get(requirement.id)
            if dependency is None:
                raise PluginHostError(
                    "PLUGIN_DEPENDENCY_MISSING",
                    f"Missing required plugin dependency {requirement.id} for {plugin_id}",
                    plugin_id=plugin_id,
                    resource_id=requirement.id,
                )

            visit(dependency)

        visit_state[plugin_id] = "visited"
        ordered.append(plugin)

    for plugin in plugins:
        visit(plugin)

    return ordered


class RuntimePluginHost(PluginHost):
    def __init__(self, *, base_path: str, title: str, version: str) -> None:
        self._metadata = HostMetadata(
            base_path=_normalize_base_path(base_path),
            title=title,
            version=version,
            host_api_version=HOST_API_VERSION,
        )
        self._routes: list[tuple[str, PluginRoute, str | None]] = []
        self._middlewares: list[tuple[int, PluginMiddleware]] = []
        self._capabilities: dict[str, CapabilityHandle] = {}
        self._extension_points: dict[str, ModuleExtensionPoint] = {}
        self._extension_values: dict[str, list[Any]] = {}
        self._startup_validations: list[PluginValidationResult] = []
        self._shutdown_callbacks: list[Callable[[], Any]] = []
        self._route_keys: set[str] = set()
        self._middleware_sequence = 0
        self._active_plugin_id: str | None = None
        self._frozen = False

    def metadata(self) -> HostMetadata:
        return self._metadata

    def modules(self) -> list[RegisteredModuleView]:
        return [RegisteredModuleView(name=name) for name in sorted({route.module for route in api_registry.routes})]

    def usecases(self) -> list[RegisteredUseCaseView]:
        return [
            RegisteredUseCaseView(
                module=route.module,
                command=route.command,
                method=route.method,
                path=route.path,
            )
            for route in api_registry.routes
        ]

    def register_route(self, route: PluginRoute | dict[str, Any]) -> None:
        self._assert_mutable()
        route = _coerce_plugin_route(route)
        final_path = _join_path(self._metadata.base_path, route.path)
        route_key = f"{route.method.upper()} {final_path}"
        if route_key in self._route_keys:
            raise PluginHostError("ROUTE_CONFLICT", f"Route conflict for {route_key}", resource_id=route_key)

        self._route_keys.add(route_key)
        self._routes.append((final_path, route, self._active_plugin_id))

    def routes(self) -> list[RegisteredPluginRouteView]:
        return [
            RegisteredPluginRouteView(
                plugin_id=plugin_id,
                id=route.id,
                method=route.method,
                path=final_path,
                visibility=route.visibility,
                openapi=route.openapi,
            )
            for final_path, route, plugin_id in self._routes
        ]

    def register_middleware(self, middleware: PluginMiddleware) -> None:
        self._assert_mutable()
        if middleware.slot not in _ALLOWED_MIDDLEWARE_SLOTS:
            raise PluginHostError(
                "PLUGIN_VALIDATION_FAILED",
                f"Unknown middleware slot: {middleware.slot}",
                resource_id=middleware.id,
            )
        self._middlewares.append(
            (
                self._middleware_sequence,
                PluginMiddleware(
                    id=middleware.id,
                    slot=middleware.slot,
                    order=middleware.order,
                    handler=_instrument_plugin_middleware(middleware, self._active_plugin_id),
                ),
            )
        )
        self._middleware_sequence += 1

    def begin_plugin_setup(self, plugin_id: str) -> None:
        self._assert_mutable()
        self._active_plugin_id = plugin_id

    def end_plugin_setup(self) -> None:
        self._active_plugin_id = None

    def expose_capability(self, capability: Capability) -> None:
        self._assert_mutable()
        if capability.id in self._capabilities:
            raise PluginHostError(
                "CAPABILITY_CONFLICT",
                f"Capability already exposed: {capability.id}",
                resource_id=capability.id,
            )
        self._capabilities[capability.id] = capability

    def resolve_capability(self, capability_id: str) -> CapabilityHandle | None:
        return self._capabilities.get(capability_id)

    def require_capability(self, capability_id: str) -> CapabilityHandle:
        capability = self.resolve_capability(capability_id)
        if capability is None:
            raise PluginHostError(
                "CAPABILITY_REQUIRED_MISSING",
                f"Missing capability: {capability_id}",
                resource_id=capability_id,
            )
        return capability

    def declare_module_extension_point(self, point: ModuleExtensionPoint) -> None:
        self._assert_mutable()
        if point.id in self._extension_points:
            raise PluginHostError(
                "MODULE_EXTENSION_POINT_CONFLICT",
                f"Duplicate extension point: {point.id}",
                resource_id=point.id,
            )
        self._extension_points[point.id] = point

    def contribute_module_extension(self, contribution: ModuleExtensionContribution) -> None:
        self._assert_mutable()
        point = self._extension_points.get(contribution.extension_point_id)
        if point is None:
            raise PluginHostError(
                "MODULE_EXTENSION_CONFLICT",
                f"Unknown extension point: {contribution.extension_point_id}",
                resource_id=contribution.extension_point_id,
            )

        key = f"{contribution.extension_point_id}:{contribution.module_name}"
        values = self._extension_values.setdefault(key, [])
        if point.mode == "single" and values:
            raise PluginHostError(
                "MODULE_EXTENSION_CONFLICT",
                f"Duplicate contribution for single extension point {key}",
                resource_id=key,
            )
        values.append(contribution.value)

    def add_startup_validation(self, validation: PluginValidationResult) -> None:
        self._assert_mutable()
        self._startup_validations.append(validation)

    def on_shutdown(self, callback: Callable[[], Any]) -> None:
        self._assert_mutable()
        self._shutdown_callbacks.append(callback)

    def freeze(self) -> None:
        self._frozen = True

    def assert_valid(self, additional_validations: list[PluginValidationResult] | None = None) -> None:
        validations = [*self._startup_validations, *(additional_validations or [])]
        for validation in validations:
            if validation.blocking:
                raise PluginHostError(
                    validation.code,
                    validation.message,
                    plugin_id=validation.plugin_id,
                    resource_id=validation.resource_id,
                )

    def build_routes(self) -> list[Route]:
        return [Route(final_path, endpoint=_build_plugin_route_handler(route, self._capabilities), methods=[route.method.upper()]) for final_path, route, _ in self._routes]

    def middlewares_for_slot(self, slot: str) -> list[PluginMiddleware]:
        candidates = [(sequence, middleware) for sequence, middleware in self._middlewares if middleware.slot == slot]
        candidates.sort(key=lambda candidate: (candidate[1].order, candidate[0]))
        return [middleware for _, middleware in candidates]

    async def shutdown(self) -> None:
        for callback in reversed(self._shutdown_callbacks):
            result = callback()
            if inspect.isawaitable(result):
                await result

    def shutdown_sync(self) -> None:
        for callback in reversed(self._shutdown_callbacks):
            result = callback()
            if inspect.isawaitable(result):
                asyncio.run(result)

    def _assert_mutable(self) -> None:
        if self._frozen:
            raise PluginHostError("PLUGIN_VALIDATION_FAILED", "Plugin host registration is frozen")


def _build_plugin_route_handler(
    route: PluginRoute,
    capabilities: dict[str, CapabilityHandle],
) -> Callable[[Request], Any]:
    async def endpoint(request: Request) -> Response:
        body: Any = None
        if request.method.upper() not in {"GET", "DELETE"}:
            try:
                body = await request.json()
            except Exception:
                body = None

        logger = getattr(request.state, LOGGER_STATE_KEY, None)
        result = route.handler(
            PluginRequestContext(
                request_id=_resolve_request_id(request, logger),
                logger=logger,
                method=request.method,
                path=request.url.path,
                headers=dict(request.headers),
                query=dict(request.query_params),
                body=body,
                path_params={key: str(value) for key, value in request.path_params.items()},
                capabilities=lambda: dict(capabilities),
            )
        )
        if inspect.isawaitable(result):
            result = await result

        if isinstance(result, Response):
            return result

        if isinstance(result, dict):
            status = int(result.get("status", 200))
            headers = result.get("headers") or None
            body_value = result.get("body")
            if body_value is None:
                return Response(status_code=status, headers=headers)
            if isinstance(body_value, (str, bytes)):
                return PlainTextResponse(body_value, status_code=status, headers=headers)
            return JSONResponse(body_value, status_code=status, headers=headers)

        if result is None:
            return Response(status_code=204)

        return JSONResponse(result)

    return endpoint


def _instrument_plugin_middleware(middleware: PluginMiddleware, plugin_id: str | None) -> Any:
    handler = middleware.handler

    class _InstrumentedMiddleware:
        def __init__(self, app: ASGIApp) -> None:
            async def observed_app(scope: Scope, receive: Receive, send: Send) -> None:
                if scope["type"] == "http":
                    clear_short_circuit_candidate(scope, middleware.id)
                await app(scope, receive, send)

            self.app = handler(observed_app)

        async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
            if scope["type"] != "http":
                await self.app(scope, receive, send)
                return

            set_short_circuit_candidate(
                scope,
                ShortCircuitAuditEntry(
                    plugin_id=plugin_id or "unknown",
                    middleware_id=middleware.id,
                    slot=middleware.slot,
                ),
            )
            try:
                await self.app(scope, receive, send)
            except Exception:
                clear_short_circuit_candidate(scope, middleware.id)
                raise

    return _InstrumentedMiddleware


def _normalize_base_path(base_path: str) -> str:
    if not base_path or base_path == "/":
        return "/"
    return "/" + base_path.strip().strip("/")


def _normalize_relative_path(path: str) -> str:
    trimmed = path.strip()
    if not trimmed:
        raise PluginHostError("PLUGIN_VALIDATION_FAILED", "Plugin route path cannot be empty")
    return "/" + trimmed.strip("/")


def _join_path(base_path: str, relative_path: str) -> str:
    normalized_base = _normalize_base_path(base_path)
    normalized_relative = _normalize_relative_path(relative_path)
    if normalized_base == "/":
        return normalized_relative
    return f"{normalized_base}{normalized_relative}".replace("//", "/")


def _resolve_request_id(request: Request, logger: Any) -> str:
    header = request.headers.get("x-request-id")
    if header:
        return header
    if isinstance(logger, RequestScopedLogger):
        return logger.trace_id
    return "unknown"


def _coerce_plugin_route(route: PluginRoute | dict[str, Any]) -> PluginRoute:
    if isinstance(route, PluginRoute):
        return route

    return PluginRoute(
        id=str(route["id"]),
        method=str(route["method"]),
        path=str(route["path"]),
        visibility=str(route["visibility"]),
        handler=route["handler"],
        openapi=route.get("openapi"),
    )