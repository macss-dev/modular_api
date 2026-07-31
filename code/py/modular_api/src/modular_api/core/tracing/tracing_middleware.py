"""The host-owned server span, as pure ASGI middleware.

**Host-owned, not plugin-owned.** Installed immediately inside ``logging_middleware``
and therefore outside every plugin middleware, which is the whole point: a span
created from inside a plugin slot would miss the plugin middleware registered before
it, leaving a hole in the waterfall exactly where cold start and early middleware live
(ADR-0005 decision 4, runbook D12).

**A third execution model, distinct from both siblings.** Shelf hands a Dart
middleware the response its inner handler produced, so that version reads the status
and ends the span in a ``finally``. Express never shows a middleware the response, so
that version listens on ``res.on('finish')``. Starlette's pure ASGI middleware does
neither: the response arrives as messages through ``send``, so the status code is read
by wrapping ``send`` and watching for ``http.response.start``.

The one thing that is *easier* here: ambient context needs no setup.
``opentelemetry`` uses ``contextvars``, which propagate through async natively — so
unlike JavaScript, where a missing ContextManager silently turns child spans into
roots, a downstream child attaches by itself with nothing registered.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable, Sequence
from typing import Any

from opentelemetry import trace
from opentelemetry.trace import SpanKind, Status, StatusCode, Tracer

from modular_api.core.tracing.propagation_policy import PropagationPolicy

#: ``scope`` key under which the server span is exposed to downstream handlers.
TRACING_SPAN_SCOPE_KEY = "modular_api.tracing.span"

#: ``scope`` key under which the resolved propagation result is exposed.
PROPAGATION_RESULT_SCOPE_KEY = "modular_api.tracing.propagation"

Scope = dict[str, Any]
Receive = Callable[[], Awaitable[dict[str, Any]]]
Send = Callable[[dict[str, Any]], Awaitable[None]]
ASGIApp = Callable[[Scope, Receive, Send], Awaitable[None]]


def tracing_middleware(
    *,
    tracer: Tracer,
    policy: PropagationPolicy | None = None,
    excluded_routes: Sequence[str] = (),
) -> Callable[[ASGIApp], ASGIApp]:
    """Return a Starlette middleware class (not an instance).

    Mirrors ``logging_middleware``'s shape so ``add_middleware`` accepts it the same
    way.
    """
    effective_policy = policy or PropagationPolicy()
    excluded = set(excluded_routes)

    class _TracingMiddleware:
        def __init__(self, app: ASGIApp) -> None:
            self._app = app

        async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
            # Health, metrics and docs are noise in a trace store. The host derives
            # this list from operational_paths rather than hardcoding it.
            if scope["type"] != "http" or scope.get("path") in excluded:
                await self._app(scope, receive, send)
                return

            method = str(scope.get("method", "GET")).upper()
            path = str(scope.get("path", "/"))
            headers = {
                key.decode("latin-1"): value.decode("latin-1")
                for key, value in scope.get("headers", [])
            }

            resolved = effective_policy.resolve(headers)

            attributes: dict[str, Any] = {
                "http.request.method": method,
                "url.path": path,
            }
            if resolved.request_id is not None:
                # The convention's name for a captured header, rather than an invented
                # one, so a reader of the trace recognises it (D6).
                attributes["http.request.header.x-request-id"] = resolved.request_id

            span = tracer.start_span(
                # Semantic convention for an HTTP server span: method then route.
                f"{method} {path}",
                # The parent comes from the resolved context, never from whatever
                # happened to be ambient — the same determinism the siblings keep.
                context=resolved.context,
                kind=SpanKind.SERVER,
                attributes=attributes,
            )

            scope[TRACING_SPAN_SCOPE_KEY] = span
            scope[PROPAGATION_RESULT_SCOPE_KEY] = resolved

            async def send_wrapper(message: dict[str, Any]) -> None:
                # The response arrives as messages rather than as a return value, so
                # the status is read here.
                if message["type"] == "http.response.start":
                    status = int(message["status"])
                    span.set_attribute("http.response.status_code", status)
                    if status >= 500:
                        # 5xx is ours; 4xx is the caller's. Marking client mistakes as
                        # errors makes an error-rate panel useless.
                        span.set_status(Status(StatusCode.ERROR, f"HTTP {status}"))
                await send(message)

            # use_span activates the span through contextvars, records an exception,
            # sets error status and ends the span — all of which this middleware would
            # otherwise have to do by hand.
            with trace.use_span(
                span,
                end_on_exit=True,
                record_exception=True,
                set_status_on_exception=True,
            ):
                await self._app(scope, receive, send_wrapper)

    return _TracingMiddleware
