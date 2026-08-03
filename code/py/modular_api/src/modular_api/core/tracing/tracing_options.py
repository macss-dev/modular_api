"""Turns tracing on and says how.

**Absent means off, and off is free.** Without this, no tracing middleware is
installed, no span is ever created, and the log format is unchanged. A REST-only API
that never asks for tracing behaves exactly as it did before (ADR-0005 invariant 3,
gate G3).

**The application supplies the tracer, not the framework** (ADR-0005 A2). Core depends
on ``opentelemetry-api``; the SDK, its exporters and any credentials belong to the
application, which builds a provider and passes it here.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass

from opentelemetry.propagators.textmap import TextMapPropagator
from opentelemetry.trace import Tracer, TracerProvider

from modular_api.core.logger.logger import TraceFieldFormatter
from modular_api.core.tracing.propagation_policy import PropagationPolicy


@dataclass(frozen=True)
class TracingOptions:
    """Distributed tracing configuration."""

    #: The application's tracer provider, from its OpenTelemetry SDK.
    tracer_provider: TracerProvider

    #: The ordered propagator chain. ``None`` means W3C Trace Context alone.
    #:
    #: A service on Google Cloud appends a Cloud Trace propagator, which is how
    #: vendor-specific formats stay out of the framework (runbook D24, roadmap
    #: invariant 7).
    propagators: Sequence[TextMapPropagator] | None = None

    #: Whether an incoming trace context is honoured at all.
    #:
    #: Defaults to ``True``, matching every official OpenTelemetry SDK. **Set it to
    #: ``False`` on a service that receives internet traffic directly**, where a caller
    #: could otherwise choose its own trace ids and collide traces (runbook D25).
    trust_incoming_trace_context: bool = True

    #: The instrumentation scope name reported to the backend.
    instrumentation_name: str = "modular_api"

    #: Builds platform-specific log correlation fields, or ``None`` for none.
    #:
    #: The framework emits open formats and nothing vendor-specific (roadmap invariant 7),
    #: so a field like Google's ``logging.googleapis.com/trace`` — which needs a project id
    #: the framework has no business knowing — is produced here by the application.
    trace_field_formatter: TraceFieldFormatter | None = None

    #: Runs when the server shuts down, before the process goes away.
    #:
    #: **The framework offers the timing; the application decides what it means.** On a
    #: scale-to-zero platform this is the only window to flush queued spans before the
    #: container dies — but the provider belongs to the application, which may share it with
    #: a worker or a scheduled job still running. Tearing down a resource the framework did
    #: not create would be presumptuous, and ``opentelemetry.trace.TracerProvider`` exposes
    #: only ``get_tracer`` anyway (runbook D8 as revised).
    #:
    #: .. code-block:: python
    #:
    #:     on_shutdown=provider.shutdown
    #:
    #: A callback that raises is swallowed: losing telemetry is bad, failing to stop the
    #: server is worse.
    on_shutdown: Callable[[], Awaitable[None] | None] | None = None

    @property
    def policy(self) -> PropagationPolicy:
        """The propagation policy these options describe."""
        if self.propagators is None:
            return PropagationPolicy(
                trust_incoming_trace_context=self.trust_incoming_trace_context
            )
        return PropagationPolicy(
            propagators=self.propagators,
            trust_incoming_trace_context=self.trust_incoming_trace_context,
        )

    @property
    def tracer(self) -> Tracer:
        """The tracer the host instruments with."""
        return self.tracer_provider.get_tracer(self.instrumentation_name)
