"""Tracing instrumentation for modular_api.

Core instruments against the OpenTelemetry **API** only. The SDK, its exporters
and any wire format belong to the application, which supplies a configured
``TracerProvider``. See ADR-0005 (amended) A1/A2 and
``tests/tracing/test_dependency_boundary.py``, which enforces the boundary.
"""

from modular_api.core.tracing.cloud_trace_propagator import (
    CLOUD_TRACE_CONTEXT_HEADER,
    CloudTraceContextPropagator,
)
from modular_api.core.tracing.propagation_policy import (
    REQUEST_ID_HEADER,
    PropagationPolicy,
    PropagationResult,
)
from modular_api.core.tracing.tracing_middleware import (
    PROPAGATION_RESULT_SCOPE_KEY,
    TRACING_SPAN_SCOPE_KEY,
    tracing_middleware,
)
from modular_api.core.tracing.tracing_options import TracingOptions

__all__ = [
    "CLOUD_TRACE_CONTEXT_HEADER",
    "REQUEST_ID_HEADER",
    "PROPAGATION_RESULT_SCOPE_KEY",
    "TRACING_SPAN_SCOPE_KEY",
    "CloudTraceContextPropagator",
    "PropagationPolicy",
    "PropagationResult",
    "TracingOptions",
    "tracing_middleware",
]
