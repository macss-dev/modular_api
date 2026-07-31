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

__all__ = [
    "CLOUD_TRACE_CONTEXT_HEADER",
    "REQUEST_ID_HEADER",
    "CloudTraceContextPropagator",
    "PropagationPolicy",
    "PropagationResult",
]
