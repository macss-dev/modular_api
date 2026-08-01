"""Transport-neutral server-span construction (gate G4).

**Nothing in this module mentions HTTP, ASGI, Starlette or a request object.** It takes a method, a
route and a header mapping, which is all any transport can supply. ``tracing_middleware`` is a thin
ASGI adapter over these functions, and the planned gRPC transport arrives the same way — as another
adapter, not as a second copy of span construction.

This was extracted when G4 was checked rather than assumed. The span had been built inline inside the
middleware's ASGI closure, which satisfied every behavioural test — they all go through HTTP, so they
could not see it — and would have forced a gRPC transport to duplicate the logic.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Mapping

from opentelemetry.trace import Span, SpanKind, Status, StatusCode, Tracer

from modular_api.core.tracing.propagation_policy import PropagationPolicy, PropagationResult


@dataclass(frozen=True, slots=True)
class ServerSpanStart:
    """The server span for one inbound call, plus what propagation resolved."""

    span: Span
    propagation: PropagationResult


def start_server_span(
    *,
    tracer: Tracer,
    method: str,
    route: str,
    headers: Mapping[str, str],
    policy: PropagationPolicy | None = None,
) -> ServerSpanStart:
    """Open a server span for one inbound call."""
    normalized_method = method.upper()
    resolved = (policy or PropagationPolicy()).resolve(headers)

    attributes: dict[str, Any] = {
        "http.request.method": normalized_method,
        "url.path": route,
    }
    if resolved.request_id is not None:
        # The convention's name for a captured header rather than an invented one, so a reader of
        # the trace recognises it (D6).
        attributes["http.request.header.x-request-id"] = resolved.request_id

    span = tracer.start_span(
        # Semantic convention for a server span: method then route.
        f"{normalized_method} {route}",
        # The parent comes from the resolved context, never from whatever happened to be ambient.
        context=resolved.context,
        kind=SpanKind.SERVER,
        attributes=attributes,
    )

    return ServerSpanStart(span=span, propagation=resolved)


def record_server_status(span: Span, status_code: int) -> None:
    """Record a response status on ``span`` without ending it.

    Separate from :func:`complete_server_span` because ASGI delivers the status as a message part
    way through the call, while the span ends later — the one place the three languages genuinely
    diverge, since shelf hands back a response and Express fires an event.
    """
    span.set_attribute("http.response.status_code", status_code)
    if status_code >= 500:
        # 5xx is ours; 4xx is the caller's. Marking client mistakes as errors makes an error-rate
        # panel useless.
        span.set_status(Status(StatusCode.ERROR, f"HTTP {status_code}"))


def complete_server_span(
    span: Span,
    *,
    status_code: int | None = None,
    error: BaseException | None = None,
) -> None:
    """Record the outcome on ``span`` and end it.

    ``status_code`` is ``None`` when the call produced no status — a transport that has no such
    concept, or a failure before one was determined.
    """
    if status_code is not None:
        record_server_status(span, status_code)

    if error is not None:
        span.record_exception(error)
        span.set_status(Status(StatusCode.ERROR, type(error).__name__))

    span.end()
