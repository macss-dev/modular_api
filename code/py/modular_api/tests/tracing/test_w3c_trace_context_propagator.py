"""Python's W3C Trace Context propagator, used as the oracle for the other two.

Python is the only one of the three language implementations whose OpenTelemetry
**API** package ships a W3C propagator: ``TraceContextTextMapPropagator`` in
``opentelemetry.trace.propagation.tracecontext``. Dart and TypeScript keep theirs
in packages we may not depend on, so we wrote our own there (runbook D26).

**So this file writes no propagator. It verifies the official one against the same
case table**, which turns Python into the reference the other two are checked
against. That is the whole reason Stage 2's review gate could be dropped: a wrong
reading of the specification shows up here as a disagreement with an
implementation maintained by the OpenTelemetry project.

Read a failure in this file accordingly. If a case fails, the likely fault is our
case table — and therefore the Dart and TypeScript implementations built from it —
not the official propagator.

Deliberately absent: the injection cases that assert what *we* choose to emit.
Those pin our behaviour, and Python's behaviour here is not ours to pin. What is
shared is extraction, which is where a specification is either read correctly or
not.
"""

from __future__ import annotations

import pytest
from opentelemetry import trace
from opentelemetry.propagators.textmap import Getter
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

TRACE_ID = "4bf92f3577b34da6a3ce929d0e0e4736"
SPAN_ID = "00f067aa0ba902b7"
SAMPLED = f"00-{TRACE_ID}-{SPAN_ID}-01"

TRACEPARENT_HEADER = "traceparent"
TRACESTATE_HEADER = "tracestate"

_propagator = TraceContextTextMapPropagator()


class _CaseInsensitiveGetter(Getter[dict[str, str]]):
    """A carrier reader with HTTP semantics: header names are case-insensitive."""

    def get(self, carrier: dict[str, str], key: str) -> list[str] | None:
        wanted = key.lower()
        for name, value in carrier.items():
            if name.lower() == wanted:
                return [value]
        return None

    def keys(self, carrier: dict[str, str]) -> list[str]:
        return list(carrier)


def _extract_from(carrier: dict[str, str]) -> trace.SpanContext:
    context = _propagator.extract(carrier, getter=_CaseInsensitiveGetter())
    return trace.get_current_span(context).get_span_context()


def _extract(traceparent: str) -> trace.SpanContext:
    return _extract_from({TRACEPARENT_HEADER: traceparent})


def test_advertises_traceparent_and_tracestate_as_its_fields() -> None:
    assert _propagator.fields == {TRACEPARENT_HEADER, TRACESTATE_HEADER}


def test_extracts_trace_id_parent_span_id_and_the_sampled_flag() -> None:
    span_context = _extract(SAMPLED)

    assert span_context.is_valid
    assert f"{span_context.trace_id:032x}" == TRACE_ID
    assert f"{span_context.span_id:016x}" == SPAN_ID
    assert span_context.trace_flags.sampled is True


def test_marks_an_extracted_span_context_as_remote() -> None:
    assert _extract(SAMPLED).is_remote is True


@pytest.mark.parametrize(
    ("flags", "expected"),
    [("01", True), ("00", False), ("03", True)],
)
def test_reads_the_sampled_flag_from_bit_0_of_the_flags_byte(
    flags: str, expected: bool
) -> None:
    # `03` is the case that matters: unknown flags must not defeat the bit we do
    # understand. If the official implementation disagreed here, our Dart and
    # TypeScript versions would be wrong.
    span_context = _extract(f"00-{TRACE_ID}-{SPAN_ID}-{flags}")

    assert span_context.trace_flags.sampled is expected


def test_carries_tracestate_verbatim_preserving_order() -> None:
    # W3C makes tracestate ordering significant: the leftmost entry is the most
    # recently updated system.
    raw = "rojo=00f067aa0ba902b7,congo=t61rcWkgMzE"
    span_context = _extract_from(
        {TRACEPARENT_HEADER: SAMPLED, TRACESTATE_HEADER: raw}
    )

    assert span_context.trace_state.to_header() == raw


def test_tolerates_an_absent_tracestate() -> None:
    assert _extract(SAMPLED).is_valid


def test_leaves_the_context_untouched_when_the_header_is_absent() -> None:
    assert _extract_from({}).is_valid is False


@pytest.mark.parametrize(
    ("label", "value"),
    [
        ("unsupported version ff", f"ff-{TRACE_ID}-{SPAN_ID}-01"),
        ("short trace id", f"00-abc-{SPAN_ID}-01"),
        ("short span id", f"00-{TRACE_ID}-abc-01"),
        ("missing flags field", f"00-{TRACE_ID}-{SPAN_ID}"),
        ("non-hex trace id", f"00-{'z' * 32}-{SPAN_ID}-01"),
        ("non-hex flags", f"00-{TRACE_ID}-{SPAN_ID}-zz"),
        ("uppercase hex", f"00-{TRACE_ID.upper()}-{SPAN_ID}-01"),
        ("all-zero trace id", f"00-{'0' * 32}-{SPAN_ID}-01"),
        ("all-zero span id", f"00-{TRACE_ID}-{'0' * 16}-01"),
        ("empty value", ""),
        ("unrelated garbage", "not-a-traceparent"),
    ],
)
def test_leaves_the_context_untouched_rather_than_raising(
    label: str, value: str
) -> None:
    assert _extract(value).is_valid is False, label


@pytest.mark.parametrize(
    ("label", "value", "expected_valid"),
    [
        ("future version 01", f"01-{TRACE_ID}-{SPAN_ID}-01", True),
        ("future version with extra fields", f"01-{TRACE_ID}-{SPAN_ID}-01-extra", True),
        ("extra fields on version 00", f"00-{TRACE_ID}-{SPAN_ID}-01-extra", False),
    ],
)
def test_forward_compatibility_with_future_versions(
    label: str, value: str, expected_valid: bool
) -> None:
    """The three cases where this oracle earned its keep.

    Our Dart and TypeScript propagators originally rejected version ``01``
    outright. This implementation accepts it, and the specification agrees: an
    implementation should read the known 55-character prefix of a higher version
    and ignore what follows.

    The bug that would have shipped is a quiet one. The day W3C publishes version
    01, every service running the rejecting code would stop honouring incoming
    trace context — and the symptom would be "tracing stopped working", with no
    error anywhere. Both implementations were corrected to match these
    expectations.
    """
    assert _extract(value).is_valid is expected_valid, label


def test_round_trips_a_value_it_produced() -> None:
    carrier: dict[str, str] = {}
    span_context = trace.SpanContext(
        trace_id=int(TRACE_ID, 16),
        span_id=int(SPAN_ID, 16),
        is_remote=False,
        trace_flags=trace.TraceFlags(trace.TraceFlags.SAMPLED),
    )
    context = trace.set_span_in_context(trace.NonRecordingSpan(span_context))
    _propagator.inject(carrier, context=context)

    assert carrier[TRACEPARENT_HEADER] == SAMPLED

    extracted = _extract_from(carrier)
    assert extracted.trace_id == span_context.trace_id
    assert extracted.span_id == span_context.span_id
    assert extracted.trace_flags.sampled is True
