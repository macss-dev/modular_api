"""Simple CORS middleware — no external dependencies.

Sets ``Access-Control-Allow-Origin``, ``Access-Control-Allow-Methods``,
and ``Access-Control-Allow-Headers`` on every response.  Preflight
``OPTIONS`` requests are short-circuited with a 204 No Content.

Mirror of ``cors()`` in TypeScript and ``exampleCorsMiddleware()``
in Dart.

Usage::

    from modular_api.middlewares.cors import cors_middleware

    app.add_middleware(cors_middleware())
    app.add_middleware(cors_middleware(origin="https://example.com"))
"""

from __future__ import annotations

from typing import Any

from starlette.requests import Request
from starlette.responses import Response
from starlette.types import ASGIApp, Receive, Scope, Send

_DEFAULT_METHODS = "GET,POST,PUT,PATCH,DELETE,OPTIONS"
_DEFAULT_HEADERS = "Content-Type,Authorization"


def cors_middleware(
    *,
    origin: str | list[str] = "*",
    methods: str = _DEFAULT_METHODS,
    allowed_headers: str = _DEFAULT_HEADERS,
) -> type:
    """Return an ASGI middleware class that injects CORS headers.

    Parameters mirror the TypeScript ``CorsOptions`` interface:
    ``origin`` (string or list), ``methods``, ``allowed_headers``.
    """
    resolved_origin = ", ".join(origin) if isinstance(origin, list) else origin

    class CorsMiddleware:
        """ASGI middleware — injects CORS headers and handles OPTIONS preflight."""

        def __init__(self, app: ASGIApp) -> None:
            self.app = app

        async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
            if scope["type"] != "http":
                await self.app(scope, receive, send)
                return

            request = Request(scope, receive, send)

            # Short-circuit OPTIONS preflight
            if request.method == "OPTIONS":
                response = Response(content=b"", status_code=204)
                response.headers["access-control-allow-origin"] = resolved_origin
                response.headers["access-control-allow-methods"] = methods
                response.headers["access-control-allow-headers"] = allowed_headers
                await response(scope, receive, send)
                return

            # For all other requests, intercept the response to inject headers
            async def send_with_cors(message: Any) -> None:
                if message["type"] == "http.response.start":
                    headers = dict(scope.get("_cors_headers", []))
                    raw_headers: list[tuple[bytes, bytes]] = list(message.get("headers", []))
                    raw_headers.append((b"access-control-allow-origin", resolved_origin.encode()))
                    raw_headers.append((b"access-control-allow-methods", methods.encode()))
                    raw_headers.append((b"access-control-allow-headers", allowed_headers.encode()))
                    message["headers"] = raw_headers
                await send(message)

            await self.app(scope, receive, send_with_cors)

    return CorsMiddleware
