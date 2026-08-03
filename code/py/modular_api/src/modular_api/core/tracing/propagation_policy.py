"""Resolves incoming request headers into a tracing context.

**Composable rather than hardcoded** (runbook D24). The chain is an ordered list of
propagators and the first to yield a valid span context wins. The default is W3C Trace
Context only: a service on Google Cloud appends a Cloud Trace propagator, which keeps
anything vendor-specific out of the framework. A service behind a B3-speaking mesh
appends a B3 propagator the same way, instead of forking.

Unlike Dart and TypeScript, the default here is the **official**
``TraceContextTextMapPropagator``: only Python's OpenTelemetry API ships one, so the
other two use an implementation we wrote (runbook D26). Same behaviour, different
provenance.

**``X-Request-ID`` is never the trace id** (runbook D6). It is read and preserved
beside the trace id, never promoted into it: callers reuse it deliberately on retries,
so adopting it would merge unrelated retries into one trace; any client could then
collide traces on purpose; and ``trace_id`` would have ambiguous provenance, sometimes
caller-supplied and sometimes generated.

**Nothing is generated here.** When no propagator matches, the returned context simply
carries no span context and the tracer starts a fresh trace with ids of its own
(runbook D7, gate G3).
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field

from opentelemetry import trace
from opentelemetry.context import Context
from opentelemetry.propagators.textmap import CarrierT, Getter, TextMapPropagator
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

#: The header carrying a caller-supplied correlation id. Preserved, never adopted.
REQUEST_ID_HEADER = "x-request-id"


@dataclass(frozen=True)
class PropagationResult:
    """What resolving the incoming headers produced."""

    #: The context to continue with. Carries a remote parent when one was accepted,
    #: and otherwise carries none -- id generation belongs to the tracer.
    context: Context

    #: The caller's ``X-Request-ID``, when it sent one. Preserved for log correlation
    #: and for forwarding on outbound calls; it is not identity.
    request_id: str | None = None

    @property
    def has_remote_parent(self) -> bool:
        """Whether a remote parent was accepted from the incoming headers."""
        return trace.get_current_span(self.context).get_span_context().is_valid


class _CaseInsensitiveGetter(Getter[Mapping[str, str]]):
    """Carrier reader with HTTP semantics.

    Header casing belongs to the carrier rather than to any propagator, so it is
    handled once here instead of in each of them.
    """

    def get(self, carrier: Mapping[str, str], key: str) -> list[str] | None:
        value = _header_value(carrier, key)
        return None if value is None else [value]

    def keys(self, carrier: Mapping[str, str]) -> list[str]:
        return list(carrier)


def _header_value(headers: Mapping[str, str], name: str) -> str | None:
    """Read a header case-insensitively, as HTTP requires."""
    wanted = name.lower()
    for key, value in headers.items():
        if key.lower() == wanted:
            return value
    return None


_GETTER: Getter[CarrierT] = _CaseInsensitiveGetter()  # type: ignore[assignment]


def _default_propagators() -> list[TextMapPropagator]:
    return [TraceContextTextMapPropagator()]


@dataclass(frozen=True)
class PropagationPolicy:
    """Resolves headers into a context plus the preserved request id."""

    #: The ordered chain. First valid span context wins.
    propagators: Sequence[TextMapPropagator] = field(
        default_factory=_default_propagators
    )

    #: Whether an incoming trace context is honoured at all (D25).
    #:
    #: Defaults to ``True``, matching every official OpenTelemetry SDK. Set it to
    #: ``False`` on a service that receives internet traffic directly, where a caller
    #: could otherwise choose its trace ids.
    trust_incoming_trace_context: bool = True

    def resolve(self, headers: Mapping[str, str]) -> PropagationResult:
        """Resolve ``headers`` into a context plus the preserved request id."""
        # Read first and unconditionally: the request id is preserved whether or not
        # incoming trace context is trusted, because it was never trusted as identity.
        request_id = _header_value(headers, REQUEST_ID_HEADER)

        if not self.trust_incoming_trace_context:
            return PropagationResult(context=Context(), request_id=request_id)

        for propagator in self.propagators:
            try:
                resolved = propagator.extract(
                    headers, context=Context(), getter=_GETTER
                )
                if trace.get_current_span(resolved).get_span_context().is_valid:
                    # First valid wins (D24).
                    return PropagationResult(context=resolved, request_id=request_id)
            except Exception:  # noqa: BLE001 - a third party's bug must not fail a request
                continue

        # No parent accepted. The tracer starts a fresh trace and generates its own
        # ids -- nothing is generated here, which is what keeps this allocation-free.
        return PropagationResult(context=Context(), request_id=request_id)
