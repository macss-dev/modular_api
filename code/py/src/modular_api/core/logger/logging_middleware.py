"""Starlette middleware — trace_id, structured JSON logs.

Mirrors ``loggingMiddleware()`` in Dart (Shelf) and TypeScript (Express).

1. Reads or generates a ``trace_id`` (from ``X-Request-ID`` header).
2. Creates a ``RequestScopedLogger`` scoped to the current request.
3. Emits a ``request received`` log at info level.
4. Stores the logger in ``request.state`` for downstream handlers.
5. Emits a ``request completed`` log (level based on status code).
6. Returns the ``X-Request-ID`` header in the response.

Requests whose path matches ``excluded_routes`` are passed through
without logging.
"""

from __future__ import annotations

import time
import uuid
from typing import Callable

from starlette.requests import Request
from starlette.responses import Response
from starlette.types import ASGIApp, Receive, Scope, Send

from modular_api.core.logger.logger import LogLevel, RequestScopedLogger, WriteFn, _default_write
from modular_api.core.request_pipeline_audit import ensure_request_pipeline_audit

# Key used in request.state to propagate the logger downstream.
LOGGER_STATE_KEY = "modular_logger"


def logging_middleware(
    *,
    log_level: LogLevel,
    service_name: str,
    excluded_routes: list[str] | None = None,
    write_fn: WriteFn | None = None,
) -> type:
    """Returns a Starlette middleware class (not an instance).

    Usage::

        app.add_middleware(
            logging_middleware(log_level=LogLevel.info, service_name="my-svc")
        )
    """
    excluded_set = set(excluded_routes or [])

    class _LoggingMiddleware:
        """ASGI middleware implementing structured request/response logging."""

        def __init__(self, app: ASGIApp) -> None:
            self.app = app

        async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
            if scope["type"] != "http":
                await self.app(scope, receive, send)
                return

            request = Request(scope, receive, send)
            audit_state = ensure_request_pipeline_audit(scope)
            path = request.url.path

            # Skip excluded routes.
            if path in excluded_set:
                await self.app(scope, receive, send)
                return

            # 1. Resolve trace_id
            header_value = request.headers.get("x-request-id", "")
            trace_id = header_value if header_value else str(uuid.uuid4())

            # 2. Create per-request logger
            logger = RequestScopedLogger(
                trace_id=trace_id,
                log_level=log_level,
                service_name=service_name,
                write_fn=write_fn or _default_write,
            )

            method = request.method.upper()
            route = path

            # 3. "request received"
            logger.log_request(method=method, route=route)

            # 4. Propagate logger via request.state
            setattr(request.state, LOGGER_STATE_KEY, logger)

            # 5. Execute inner app and capture response status
            start = time.perf_counter()
            status_code = 500  # default for unhandled errors

            # Intercept the response start to capture status_code.
            async def send_wrapper(message: dict) -> None:
                nonlocal status_code
                if message["type"] == "http.response.start":
                    status_code = message["status"]
                    # Inject X-Request-ID header into the response.
                    headers = list(message.get("headers", []))
                    headers.append((b"x-request-id", trace_id.encode()))
                    message = {**message, "headers": headers}
                await send(message)

            try:
                await self.app(scope, receive, send_wrapper)
                duration_ms = (time.perf_counter() - start) * 1000

                # 6. "request completed"
                logger.log_response(
                    method=method,
                    route=route,
                    status_code=status_code,
                    duration_ms=duration_ms,
                    extra=None
                    if audit_state.short_circuit is None
                    else {
                        "short_circuit": True,
                        "short_circuit_plugin_id": audit_state.short_circuit.plugin_id,
                        "short_circuit_middleware_id": audit_state.short_circuit.middleware_id,
                        "short_circuit_slot": audit_state.short_circuit.slot,
                    },
                )
            except Exception:
                duration_ms = (time.perf_counter() - start) * 1000
                logger.log_unhandled_exception(route=route, duration_ms=duration_ms)
                raise

    return _LoggingMiddleware
