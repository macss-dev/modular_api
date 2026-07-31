"""Propagator for Google Cloud's legacy ``X-Cloud-Trace-Context`` header.

The OpenTelemetry API ships W3C ``traceparent`` and Baggage propagators but no
Google Cloud propagator, so this one is ours. Cloud Run injects both headers; W3C
is preferred and this is the documented fallback, which is why the precedence
policy consults it second.

Format: ``TRACE_ID/SPAN_ID;o=OPTIONS``, where

- ``TRACE_ID`` is 32 hex characters, case-insensitive per Google's docs;
- **``SPAN_ID`` is the decimal representation of an unsigned 64-bit integer** —
  not hex. Reading it as hex yields a wrong parent and a silently broken
  waterfall. Python represents span ids as integers, so decimal is the native
  form here and no conversion is needed on the way in; the hazard that bites Dart
  and JavaScript does not exist, but the 64-bit upper bound is still enforced.
- ``OPTIONS`` carries ``o=1`` (parent sampled) or ``o=0`` (not sampled).

Header-name casing is deliberately not this class's concern. HTTP header
semantics belong to the carrier, so :attr:`fields` reports the lowercase
canonical name and lookup goes through the supplied getter.

The Dart and TypeScript counterparts are
``lib/src/core/tracing/cloud_trace_propagator.dart`` and
``src/core/tracing/cloudTracePropagator.ts``. Same behaviour, idiomatic here.
"""

from __future__ import annotations

import re

from opentelemetry import trace
from opentelemetry.context import Context
from opentelemetry.propagators.textmap import (
    CarrierT,
    Getter,
    Setter,
    TextMapPropagator,
    default_getter,
    default_setter,
)

CLOUD_TRACE_CONTEXT_HEADER = "x-cloud-trace-context"

_TRACE_ID_PATTERN = re.compile(r"^[0-9a-f]{32}$")
_DECIMAL_PATTERN = re.compile(r"^[0-9]+$")

#: 2^64-1. The span id is an unsigned 64-bit integer.
_MAX_UNSIGNED_64 = 0xFFFFFFFFFFFFFFFF


class CloudTraceContextPropagator(TextMapPropagator):
    """Reads and writes the legacy Google Cloud trace header."""

    @property
    def fields(self) -> set[str]:
        return {CLOUD_TRACE_CONTEXT_HEADER}

    def inject(
        self,
        carrier: CarrierT,
        context: Context | None = None,
        setter: Setter[CarrierT] = default_setter,
    ) -> None:
        span_context = trace.get_current_span(context).get_span_context()
        if not span_context.is_valid:
            return

        option = "1" if span_context.trace_flags.sampled else "0"
        setter.set(
            carrier,
            CLOUD_TRACE_CONTEXT_HEADER,
            f"{span_context.trace_id:032x}/{span_context.span_id};o={option}",
        )

    def extract(
        self,
        carrier: CarrierT,
        context: Context | None = None,
        getter: Getter[CarrierT] = default_getter,
    ) -> Context:
        # A malformed upstream header must never fail a request, so every exit
        # returns the untouched context and the whole body is guarded.
        if context is None:
            context = Context()

        try:
            values = getter.get(carrier, CLOUD_TRACE_CONTEXT_HEADER)
            if not values:
                return context

            raw = values[0]
            separator = raw.find("/")
            if separator <= 0:
                return context

            # Google documents the trace id as case-insensitive hex; W3C requires
            # lowercase. Normalising here is the deliberate asymmetry.
            trace_id_hex = raw[:separator].lower()
            if not _TRACE_ID_PATTERN.match(trace_id_hex):
                return context

            trace_id = int(trace_id_hex, 16)
            if trace_id == trace.INVALID_TRACE_ID:
                return context

            remainder = raw[separator + 1 :]
            sampled = False

            options_at = remainder.find(";")
            if options_at >= 0:
                sampled = _is_sampled(remainder[options_at + 1 :])
                remainder = remainder[:options_at]

            if not _DECIMAL_PATTERN.match(remainder):
                return context

            span_id = int(remainder)
            if span_id == trace.INVALID_SPAN_ID or span_id > _MAX_UNSIGNED_64:
                return context

            span_context = trace.SpanContext(
                trace_id=trace_id,
                span_id=span_id,
                is_remote=True,
                trace_flags=trace.TraceFlags(
                    trace.TraceFlags.SAMPLED if sampled else trace.TraceFlags.DEFAULT
                ),
            )

            return trace.set_span_in_context(
                trace.NonRecordingSpan(span_context), context
            )
        except Exception:  # noqa: BLE001 - a broken header must not fail a request
            return context


def _is_sampled(options: str) -> bool:
    """Read the ``o=`` option, tolerating other options alongside it."""
    for option in options.split(";"):
        trimmed = option.strip()
        if trimmed.startswith("o="):
            return trimmed[2:] == "1"
    return False
