"""Python mirror of ``test/tracing/propagation_policy_test.dart``.

The case table was reviewed once against the Dart version. This policy is ours — no
reference implementation exists anywhere — which is why Stage 3 kept the review gate
that Stage 2 dropped.

Python's ``Context`` model is the most different of the three, so this file is where
G6's clarification gets exercised immediately: **parity compares behaviour, never
internal representation.** A bare ``SpanContext`` cannot be placed in a ``Context``
here — it is wrapped in a ``NonRecordingSpan`` — and ``get_current_span`` on an
untouched context returns the invalid span rather than ``None``. Neither fact changes
what the policy must *do*.

One asymmetry that is deliberate rather than accidental: Python's default chain uses
the **official** ``TraceContextTextMapPropagator``, while Dart and TypeScript use the
one we wrote, because only Python's OTel API ships it (runbook D26). Same behaviour,
different provenance.
"""

from __future__ import annotations

from opentelemetry import trace
from opentelemetry.context import Context
from opentelemetry.propagators.textmap import CarrierT, Getter, Setter, TextMapPropagator
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

from modular_api.core.tracing.propagation_policy import (
    REQUEST_ID_HEADER,
    PropagationPolicy,
)

TRACE_ID = "4bf92f3577b34da6a3ce929d0e0e4736"
SPAN_ID = "00f067aa0ba902b7"
TRACEPARENT = f"00-{TRACE_ID}-{SPAN_ID}-01"
TRACEPARENT_HEADER = "traceparent"
UUID = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"


def _span_context(context: Context) -> trace.SpanContext:
    return trace.get_current_span(context).get_span_context()


# --- defaults ---------------------------------------------------------------


def test_the_default_chain_is_w3c_trace_context_alone() -> None:
    # Not W3C plus Cloud Trace: a Google propagator in core would contradict roadmap
    # invariant 7. A service on Cloud Run appends one.
    policy = PropagationPolicy()

    assert len(policy.propagators) == 1
    assert isinstance(policy.propagators[0], TraceContextTextMapPropagator)


def test_incoming_trace_context_is_trusted_by_default() -> None:
    assert PropagationPolicy().trust_incoming_trace_context is True


# --- resolution -------------------------------------------------------------


def test_accepts_a_remote_parent_from_traceparent() -> None:
    result = PropagationPolicy().resolve({TRACEPARENT_HEADER: TRACEPARENT})

    assert result.has_remote_parent is True
    span_context = _span_context(result.context)
    assert f"{span_context.trace_id:032x}" == TRACE_ID
    assert f"{span_context.span_id:016x}" == SPAN_ID
    assert span_context.is_remote is True


def test_carries_no_span_context_when_no_propagator_matches() -> None:
    # The tracer generates ids for a root span. This class does not.
    result = PropagationPolicy().resolve({})

    assert result.has_remote_parent is False
    assert _span_context(result.context).is_valid is False


def test_carries_no_span_context_when_the_header_is_malformed() -> None:
    result = PropagationPolicy().resolve({TRACEPARENT_HEADER: "not-a-traceparent"})

    assert result.has_remote_parent is False


def test_resolves_header_names_case_insensitively() -> None:
    result = PropagationPolicy().resolve({"TraceParent": TRACEPARENT})

    assert result.has_remote_parent is True


# --- chain order (D24) ------------------------------------------------------


def test_the_first_propagator_to_yield_a_valid_context_wins() -> None:
    policy = PropagationPolicy(
        propagators=[_FixedPropagator("a" * 32), _FixedPropagator("b" * 32)]
    )

    assert f"{_span_context(policy.resolve({}).context).trace_id:032x}" == "a" * 32


def test_falls_through_to_the_next_propagator_when_the_first_yields_nothing() -> None:
    policy = PropagationPolicy(
        propagators=[_NeverMatchesPropagator(), TraceContextTextMapPropagator()]
    )

    result = policy.resolve({TRACEPARENT_HEADER: TRACEPARENT})

    assert f"{_span_context(result.context).trace_id:032x}" == TRACE_ID


def test_a_propagator_that_raises_does_not_break_resolution() -> None:
    # A third-party propagator is not our code. One misbehaving entry must not fail a
    # request; the chain continues.
    policy = PropagationPolicy(
        propagators=[_RaisingPropagator(), TraceContextTextMapPropagator()]
    )

    result = policy.resolve({TRACEPARENT_HEADER: TRACEPARENT})

    assert f"{_span_context(result.context).trace_id:032x}" == TRACE_ID


def test_an_empty_chain_resolves_to_a_context_with_no_span_context() -> None:
    policy = PropagationPolicy(propagators=[])

    assert policy.resolve({TRACEPARENT_HEADER: TRACEPARENT}).has_remote_parent is False


# --- X-Request-ID is preserved, never adopted (D6) --------------------------


def test_request_id_is_exposed() -> None:
    assert PropagationPolicy().resolve({REQUEST_ID_HEADER: UUID}).request_id == UUID


def test_request_id_is_none_when_the_caller_sent_none() -> None:
    assert PropagationPolicy().resolve({}).request_id is None


def test_request_id_never_becomes_the_trace_id_even_when_a_valid_uuid() -> None:
    # Stripping the dashes from a v4 UUID would produce a structurally valid trace id,
    # which is exactly why this needs asserting rather than assuming.
    result = PropagationPolicy().resolve({REQUEST_ID_HEADER: UUID})

    assert result.has_remote_parent is False
    assert _span_context(result.context).is_valid is False


def test_request_id_does_not_override_a_trace_id_from_traceparent() -> None:
    result = PropagationPolicy().resolve(
        {TRACEPARENT_HEADER: TRACEPARENT, REQUEST_ID_HEADER: UUID}
    )

    assert f"{_span_context(result.context).trace_id:032x}" == TRACE_ID
    assert result.request_id == UUID


def test_a_non_uuid_request_id_is_preserved_verbatim() -> None:
    # We do not validate the caller's correlation token. It is opaque to us.
    result = PropagationPolicy().resolve({REQUEST_ID_HEADER: "order-42/retry-3"})

    assert result.request_id == "order-42/retry-3"


def test_the_same_request_id_twice_does_not_produce_one_shared_trace() -> None:
    # The retry case that motivated reversing D6: callers reuse X-Request-ID
    # deliberately as an idempotency key, so adopting it would merge unrelated retries
    # into a single trace with several unconnected trees.
    policy = PropagationPolicy()

    first = policy.resolve({REQUEST_ID_HEADER: UUID})
    second = policy.resolve({REQUEST_ID_HEADER: UUID})

    assert first.has_remote_parent is False
    assert second.has_remote_parent is False
    assert first.request_id == second.request_id


# --- trust_incoming_trace_context (D25) -------------------------------------


def test_when_untrusted_an_incoming_traceparent_is_ignored() -> None:
    policy = PropagationPolicy(trust_incoming_trace_context=False)

    result = policy.resolve({TRACEPARENT_HEADER: TRACEPARENT})

    assert result.has_remote_parent is False
    assert _span_context(result.context).is_valid is False


def test_when_untrusted_every_propagator_in_the_chain_is_skipped() -> None:
    policy = PropagationPolicy(
        trust_incoming_trace_context=False, propagators=[_FixedPropagator(TRACE_ID)]
    )

    assert policy.resolve({}).has_remote_parent is False


def test_when_untrusted_the_request_id_is_still_preserved() -> None:
    # It was never trusted as identity, so there is nothing to distrust. Log
    # correlation and outbound forwarding (D23) keep working either way.
    policy = PropagationPolicy(trust_incoming_trace_context=False)

    assert policy.resolve({REQUEST_ID_HEADER: "order-42"}).request_id == "order-42"


# --- resolution allocates no span (D7, G3) ----------------------------------


def test_a_resolved_remote_parent_records_nothing() -> None:
    """The portable form of D7, per G6.

    Dart keeps SpanContext and Span as separate context keys, so there the assertion
    is ``context.span is null``. Python has no separate key -- a SpanContext is
    wrapped in a NonRecordingSpan -- so the portable statement is "nothing is
    recording", which holds in every implementation.
    """
    result = PropagationPolicy().resolve({TRACEPARENT_HEADER: TRACEPARENT})

    assert _span_context(result.context).is_valid is True
    assert trace.get_current_span(result.context).is_recording() is False


def test_an_unmatched_resolution_holds_neither() -> None:
    result = PropagationPolicy().resolve({})

    assert _span_context(result.context).is_valid is False
    assert trace.get_current_span(result.context).is_recording() is False


# --- fakes ------------------------------------------------------------------


class _FixedPropagator(TextMapPropagator):
    """Always yields the same span context, regardless of the carrier."""

    def __init__(self, trace_id_hex: str) -> None:
        self._trace_id_hex = trace_id_hex

    @property
    def fields(self) -> set[str]:
        return set()

    def inject(
        self,
        carrier: CarrierT,
        context: Context | None = None,
        setter: Setter[CarrierT] | None = None,
    ) -> None:
        return None

    def extract(
        self,
        carrier: CarrierT,
        context: Context | None = None,
        getter: Getter[CarrierT] | None = None,
    ) -> Context:
        span_context = trace.SpanContext(
            trace_id=int(self._trace_id_hex, 16),
            span_id=int(SPAN_ID, 16),
            is_remote=True,
            trace_flags=trace.TraceFlags(trace.TraceFlags.SAMPLED),
        )
        return trace.set_span_in_context(
            trace.NonRecordingSpan(span_context), context or Context()
        )


class _NeverMatchesPropagator(TextMapPropagator):
    """Never yields anything, like a propagator whose header is absent."""

    @property
    def fields(self) -> set[str]:
        return set()

    def inject(
        self,
        carrier: CarrierT,
        context: Context | None = None,
        setter: Setter[CarrierT] | None = None,
    ) -> None:
        return None

    def extract(
        self,
        carrier: CarrierT,
        context: Context | None = None,
        getter: Getter[CarrierT] | None = None,
    ) -> Context:
        return context or Context()


class _RaisingPropagator(TextMapPropagator):
    """Misbehaves, to prove the chain survives a third party's bug."""

    @property
    def fields(self) -> set[str]:
        return set()

    def inject(
        self,
        carrier: CarrierT,
        context: Context | None = None,
        setter: Setter[CarrierT] | None = None,
    ) -> None:
        return None

    def extract(
        self,
        carrier: CarrierT,
        context: Context | None = None,
        getter: Getter[CarrierT] | None = None,
    ) -> Context:
        raise RuntimeError("a third-party propagator raised")
