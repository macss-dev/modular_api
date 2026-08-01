"""Instrumentation for one outbound call.

**Zero configuration on purpose.** The parent comes from the ambient context — the server
span the host made active, which ``contextvars`` carry here without anything being threaded
through call signatures — and the tracer from the global provider. When no OpenTelemetry SDK
is configured both are no-ops, so a consumer who never enables tracing gets no spans, no
headers and no measurable cost. Nothing is threaded into ``ServiceClientConfig``.

**Injection goes through the global propagator**, never a propagator of our own. This package
does not depend on ``macss-modular-api`` (runbook D21), so it cannot reach the framework's
propagator — and per the OpenTelemetry API's own guidance it should not: instrumentation
libraries read the global and leave setting it to the SDK or the host. That also means
whatever chain the application configured is honoured here, including a Cloud Trace
propagator it appended, without this package knowing such a thing exists.

The Dart and TypeScript counterparts are ``lib/src/client_tracing.dart`` and
``src/clientTracing.ts``.
"""

from __future__ import annotations

from urllib.parse import urlparse

from opentelemetry import propagate, trace
from opentelemetry.trace import SpanKind, Status, StatusCode

#: The header carrying a caller-supplied correlation id.
REQUEST_ID_HEADER = "x-request-id"


class ClientCallTracing:
    """Handle for one instrumented outbound call. ``complete`` must be called once."""

    __slots__ = ("_span",)

    def __init__(self, span: trace.Span | None) -> None:
        self._span = span

    @classmethod
    def start(
        cls,
        *,
        method: str,
        operation_id: str,
        url: str,
        headers: dict[str, str],
        inbound_request_id: str | None = None,
    ) -> ClientCallTracing:
        """Start a client span and inject trace context plus the request id into ``headers``."""
        # Forwarded whether or not tracing is on. Envoy's tracing documentation lists
        # x-request-id propagation as an obligation separate from trace context, and it is the
        # one correlation header nearly every stack implements — so it survives a hop into a
        # service with no tracing at all (runbook D23). We forward, never invent: a chain with
        # no request id keeps having none.
        if inbound_request_id:
            headers.setdefault(REQUEST_ID_HEADER, inbound_request_id)

        parent_span = trace.get_current_span()

        # No recording parent means tracing is off for this request. A non-recording span and
        # a header nobody will read would be cost with no benefit.
        if not parent_span.is_recording():
            return cls(None)

        target = urlparse(url)
        attributes: dict[str, object] = {"http.request.method": method}
        if target.hostname:
            # server.address plus url.path rather than the full URL, which can carry
            # identifiers in its path or query.
            attributes["server.address"] = target.hostname
            if target.port is not None:
                attributes["server.port"] = target.port
            attributes["url.path"] = target.path

        span = trace.get_tracer("modular_api_rest_client").start_span(
            # Semantic convention for a client span: the method, qualified by what was called.
            # The operation id is more useful than a bare method and safer than a full URL.
            f"{method} {operation_id}",
            kind=SpanKind.CLIENT,
            attributes=attributes,
        )

        propagate.inject(headers, context=trace.set_span_in_context(span))

        return cls(span)

    def complete(
        self,
        *,
        status_code: int | None = None,
        error: BaseException | None = None,
    ) -> None:
        """End the span, recording the outcome.

        ``status_code`` is ``None`` when the call never produced a response — a timeout, a DNS
        failure, a refused connection. That is always an error; a status code is an error at
        4xx and above, because a client span's failure is the *call* failing rather than the
        server disagreeing.
        """
        span = self._span
        if span is None:
            return

        if status_code is not None:
            span.set_attribute("http.response.status_code", status_code)

        if error is not None:
            span.record_exception(error)
            span.set_status(Status(StatusCode.ERROR, "request failed"))
        elif status_code is None:
            span.set_status(Status(StatusCode.ERROR, "no response"))
        elif status_code >= 400:
            # Unlike a server span, where 4xx is the caller's mistake, a 4xx here means *our*
            # outbound call failed. The distinction matters when reading a waterfall.
            span.set_status(Status(StatusCode.ERROR, f"HTTP {status_code}"))

        span.end()
