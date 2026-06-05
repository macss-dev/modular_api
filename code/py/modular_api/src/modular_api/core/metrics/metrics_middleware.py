"""Starlette middleware and handler for Prometheus metrics collection.

Mirrors ``metricsMiddleware()`` / ``metricsHandler()`` in Dart (Shelf)
and TypeScript (Express).

Records per-request:
  - ``requests_total``   — counter with labels: method, route, status_code
  - ``requests_in_flight`` — gauge (inc on entry, dec on exit)
  - ``request_duration``  — histogram with labels: method, route, status_code
"""

from __future__ import annotations

import time
from typing import Any

from starlette.requests import Request
from starlette.responses import Response
from starlette.types import ASGIApp, Receive, Scope, Send

from modular_api.core.metrics.metric import Counter, Gauge, Histogram
from modular_api.core.metrics.metric_registry import MetricRegistry


def metrics_middleware(
    *,
    requests_total: Counter,
    requests_in_flight: Gauge,
    request_duration: Histogram,
    excluded_routes: list[str] | None = None,
    registered_paths: list[str] | None = None,
) -> type:
    """Returns a Starlette middleware class that instruments HTTP requests."""

    excluded_set = set(excluded_routes or [])
    registered_set = set(registered_paths or [])

    class _MetricsMiddleware:
        """ASGI middleware recording request metrics in Prometheus format."""

        def __init__(self, app: ASGIApp) -> None:
            self.app = app

        async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
            if scope["type"] != "http":
                await self.app(scope, receive, send)
                return

            request = Request(scope, receive, send)
            path = request.url.path

            # Skip excluded routes.
            if path in excluded_set:
                await self.app(scope, receive, send)
                return

            method = request.method.upper()
            route = path if path in registered_set else "UNMATCHED"

            requests_in_flight.inc()
            start = time.perf_counter()
            status_code = 500  # default for unhandled errors

            async def send_wrapper(message: dict) -> None:
                nonlocal status_code
                if message["type"] == "http.response.start":
                    status_code = message["status"]
                await send(message)

            try:
                await self.app(scope, receive, send_wrapper)
                duration_secs = time.perf_counter() - start
                labels = {
                    "method": method,
                    "route": route,
                    "status_code": str(status_code),
                }
                requests_total.labels(labels).inc()
                request_duration.labels(labels).observe(duration_secs)
            except Exception:
                duration_secs = time.perf_counter() - start
                labels = {
                    "method": method,
                    "route": route,
                    "status_code": "500",
                }
                requests_total.labels(labels).inc()
                request_duration.labels(labels).observe(duration_secs)
                raise
            finally:
                requests_in_flight.dec()

    return _MetricsMiddleware


def metrics_handler(registry: MetricRegistry) -> Any:
    """Returns a Starlette endpoint that serves Prometheus text format.

    Always returns HTTP 200 with content type
    ``text/plain; version=0.0.4; charset=utf-8``.
    """

    async def endpoint(request: Request) -> Response:
        body = registry.serialize()
        return Response(
            content=body,
            status_code=200,
            media_type="text/plain; version=0.0.4; charset=utf-8",
        )

    return endpoint
