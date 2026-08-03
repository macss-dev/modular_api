"""Python mirror of ``test/tracing/cloud_trace_propagator_test.dart``.

The case table was reviewed once against the Dart version and is repeated here
rather than re-derived — same names, same expectations. What differs is idiom,
and here it differs more than in TypeScript:

- ``fields`` is a property returning a ``set``, not a method returning a list.
- ``Getter.get`` returns ``list[str] | None`` rather than a scalar.
- Trace and span ids are **integers**, not hex strings. So the decimal span id
  that the Dart and TypeScript versions must convert is, in Python, already the
  native representation — and Python's arbitrary-precision ints mean 2^64-1 needs
  no special handling at all. The bound check still matters, because 2^64 must be
  rejected; the overflow hazard does not exist.
- A bare ``SpanContext`` cannot be placed in a ``Context`` directly: it is wrapped
  in a ``NonRecordingSpan`` and installed with ``set_span_in_context``.
- "Left untouched" is expressed as an invalid span context rather than as absence,
  because ``get_current_span`` on an untouched context returns the invalid span.

Assertions render span ids as 16 hex digits so the expected values read the same
as in the other two implementations.
"""

from __future__ import annotations

import pytest
from opentelemetry import trace
from opentelemetry.propagators.textmap import Getter, Setter

from modular_api.core.tracing.cloud_trace_propagator import (
    CLOUD_TRACE_CONTEXT_HEADER,
    CloudTraceContextPropagator,
)

TRACE_ID = "4bf92f3577b34da6a3ce929d0e0e4736"

_propagator = CloudTraceContextPropagator()


class _CaseInsensitiveGetter(Getter[dict[str, str]]):
    """A carrier reader with HTTP semantics: header names are case-insensitive.

    Keeping that responsibility here rather than in the propagator is deliberate —
    header casing belongs to the carrier.
    """

    def get(self, carrier: dict[str, str], key: str) -> list[str] | None:
        wanted = key.lower()
        for name, value in carrier.items():
            if name.lower() == wanted:
                return [value]
        return None

    def keys(self, carrier: dict[str, str]) -> list[str]:
        return list(carrier)


class _DictSetter(Setter[dict[str, str]]):
    def set(self, carrier: dict[str, str], key: str, value: str) -> None:
        carrier[key] = value


def _extract_from(carrier: dict[str, str]) -> trace.SpanContext:
    context = _propagator.extract(carrier, getter=_CaseInsensitiveGetter())
    return trace.get_current_span(context).get_span_context()


def _extract(header_value: str) -> trace.SpanContext:
    return _extract_from({CLOUD_TRACE_CONTEXT_HEADER: header_value})


def _inject(span_context: trace.SpanContext) -> dict[str, str]:
    carrier: dict[str, str] = {}
    context = trace.set_span_in_context(trace.NonRecordingSpan(span_context))
    _propagator.inject(carrier, context=context, setter=_DictSetter())
    return carrier


def _span_context(span_id: int, *, sampled: bool = True) -> trace.SpanContext:
    return trace.SpanContext(
        trace_id=int(TRACE_ID, 16),
        span_id=span_id,
        is_remote=False,
        trace_flags=trace.TraceFlags(
            trace.TraceFlags.SAMPLED if sampled else trace.TraceFlags.DEFAULT
        ),
    )


def test_advertises_the_single_carrier_key_it_reads_and_writes() -> None:
    assert _propagator.fields == {CLOUD_TRACE_CONTEXT_HEADER}


def test_extracts_a_32_hex_trace_id_and_a_decimal_span_id() -> None:
    span_context = _extract(f"{TRACE_ID}/1;o=1")

    assert span_context.is_valid
    assert f"{span_context.trace_id:032x}" == TRACE_ID
    assert f"{span_context.span_id:016x}" == "0000000000000001"


def test_reads_the_span_id_as_decimal_not_hex() -> None:
    # 1234567890 decimal is 0x499602D2. Read as hex it would be 0x1234567890 ->
    # '0000001234567890', which is the bug this asserts against.
    span_context = _extract(f"{TRACE_ID}/1234567890;o=1")

    assert f"{span_context.span_id:016x}" == "00000000499602d2"
    assert f"{span_context.span_id:016x}" != "0000001234567890"


def test_handles_a_span_id_at_the_top_of_the_unsigned_64_bit_range() -> None:
    # Python ints are arbitrary precision, so unlike Dart and JavaScript this
    # cannot overflow. The case is kept for parity, and because the upper bound
    # still has to be enforced.
    span_context = _extract(f"{TRACE_ID}/18446744073709551615;o=1")

    assert f"{span_context.span_id:016x}" == "ffffffffffffffff"


def test_treats_o_1_as_sampled_and_o_0_as_not_sampled() -> None:
    assert _extract(f"{TRACE_ID}/1;o=1").trace_flags.sampled is True
    assert _extract(f"{TRACE_ID}/1;o=0").trace_flags.sampled is False


def test_defaults_to_not_sampled_when_the_options_segment_is_absent() -> None:
    span_context = _extract(f"{TRACE_ID}/1")

    assert span_context.is_valid
    assert span_context.trace_flags.sampled is False


def test_accepts_a_case_insensitive_trace_id_and_normalises_it() -> None:
    span_context = _extract(f"{TRACE_ID.upper()}/1;o=1")

    assert f"{span_context.trace_id:032x}" == TRACE_ID


def test_marks_an_extracted_span_context_as_remote() -> None:
    assert _extract(f"{TRACE_ID}/1;o=1").is_remote is True


def test_leaves_the_context_untouched_when_the_header_is_absent() -> None:
    assert _extract_from({}).is_valid is False


@pytest.mark.parametrize(
    ("label", "value"),
    [
        ("no span id segment", TRACE_ID),
        ("empty span id", f"{TRACE_ID}/"),
        ("non-numeric span id", f"{TRACE_ID}/abc"),
        ("span id beyond 64 bits", f"{TRACE_ID}/18446744073709551616"),
        ("short trace id", "abc/1"),
        ("non-hex trace id", f"{'z' * 32}/1"),
        ("all-zero trace id", f"{'0' * 32}/1"),
        ("all-zero span id", f"{TRACE_ID}/0"),
        ("empty value", ""),
        ("unrelated garbage", "not-a-trace-context"),
    ],
)
def test_leaves_the_context_untouched_rather_than_raising(label: str, value: str) -> None:
    assert _extract(value).is_valid is False, label


def test_injects_the_header_back_in_googles_format() -> None:
    carrier = _inject(_span_context(0x499602D2))

    assert carrier[CLOUD_TRACE_CONTEXT_HEADER] == f"{TRACE_ID}/1234567890;o=1"


def test_injects_o_0_for_a_non_sampled_span_context() -> None:
    carrier = _inject(_span_context(1, sampled=False))

    assert carrier[CLOUD_TRACE_CONTEXT_HEADER] == f"{TRACE_ID}/1;o=0"


def test_injects_nothing_when_there_is_no_span_context_to_propagate() -> None:
    carrier: dict[str, str] = {}
    _propagator.inject(carrier, setter=_DictSetter())

    assert carrier == {}


def test_round_trips_a_value_it_produced() -> None:
    original = _span_context(0x499602D2)

    extracted = _extract_from(_inject(original))

    assert extracted.trace_id == original.trace_id
    assert extracted.span_id == original.span_id
    assert extracted.trace_flags.sampled is True
