from __future__ import annotations

from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

from modular_api.core.logger.logging_middleware import LOGGER_STATE_KEY


def error_response_middleware() -> type:
    class _ErrorResponseMiddleware:
        def __init__(self, app: ASGIApp) -> None:
            self.app = app

        async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
            if scope["type"] != "http":
                await self.app(scope, receive, send)
                return

            try:
                await self.app(scope, receive, send)
            except Exception as exc:
                request = Request(scope, receive, send)
                logger = getattr(request.state, LOGGER_STATE_KEY, None)
                if logger is not None:
                    logger.error(
                        "Unhandled error in request pipeline",
                        fields={"error": str(exc), "status": 500},
                    )
                response = JSONResponse({"error": "Internal server error"}, status_code=500)
                await response(scope, receive, send)

    return _ErrorResponseMiddleware