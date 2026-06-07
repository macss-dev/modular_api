"""Starlette endpoint for GET /health — IETF Health Check Response Format."""

from __future__ import annotations

import json
from typing import Callable, Awaitable

from starlette.requests import Request
from starlette.responses import Response

from modular_api.core.health.health_service import HealthService


def health_handler(
    service: HealthService,
) -> Callable[[Request], Awaitable[Response]]:
    """Create an async Starlette endpoint that evaluates all health checks.

    Returns 200 for pass/warn, 503 for fail with ``application/health+json``.
    """

    async def handler(request: Request) -> Response:
        health_response = await service.evaluate()
        return Response(
            content=json.dumps(health_response.to_json()),
            status_code=health_response.http_status_code,
            media_type="application/health+json",
        )

    return handler
