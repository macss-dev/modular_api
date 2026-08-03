import {
  isValidSpanId,
  isValidTraceId,
  TraceFlags,
  trace,
  type Context,
  type TextMapGetter,
  type TextMapPropagator,
  type TextMapSetter,
} from '@opentelemetry/api';

/** The carrier key this propagator reads and writes. */
export const CLOUD_TRACE_CONTEXT_HEADER = 'x-cloud-trace-context';

const TRACE_ID_PATTERN = /^[0-9a-f]{32}$/;
const DECIMAL_PATTERN = /^[0-9]+$/;

/** 2^64-1 — the span id is an unsigned 64-bit integer, so the bound is a BigInt. */
const MAX_UNSIGNED_64 = BigInt('0xffffffffffffffff');

/**
 * Propagates Google Cloud's legacy `X-Cloud-Trace-Context` header.
 *
 * The OTel API ships W3C `traceparent` and Baggage propagators but no Google
 * Cloud propagator, so this one is ours. Cloud Run injects both headers; W3C is
 * preferred and this is the documented fallback, which is why the precedence
 * policy consults it second.
 *
 * Format: `TRACE_ID/SPAN_ID;o=OPTIONS`, where
 *
 * - `TRACE_ID` is 32 hex characters, case-insensitive per Google's docs;
 * - **`SPAN_ID` is the decimal representation of an unsigned 64-bit integer** —
 *   not hex. Reading it as hex yields a wrong parent and a silently broken
 *   waterfall, which is the most likely defect in this file. JavaScript's Number
 *   cannot hold 2^64-1 either, so the conversion goes through BigInt.
 * - `OPTIONS` carries `o=1` (parent sampled) or `o=0` (not sampled).
 *
 * Header-name casing is deliberately not this class's concern. HTTP header
 * semantics belong to the carrier, so {@link fields} returns the lowercase
 * canonical name and lookup goes through the supplied getter.
 *
 * The Dart counterpart is `lib/src/core/tracing/cloud_trace_propagator.dart`.
 * Same behaviour; this version leans on `isValidTraceId` / `isValidSpanId`, which
 * the JavaScript API provides and the Dart API does not.
 */
export class CloudTraceContextPropagator implements TextMapPropagator<unknown> {
  fields(): string[] {
    return [CLOUD_TRACE_CONTEXT_HEADER];
  }

  inject(context: Context, carrier: unknown, setter: TextMapSetter<unknown>): void {
    const spanContext = trace.getSpanContext(context);
    if (spanContext === undefined) return;
    if (!isValidTraceId(spanContext.traceId) || !isValidSpanId(spanContext.spanId)) return;

    // Back to decimal, which is what makes this header Google's and not W3C's.
    const spanId = BigInt(`0x${spanContext.spanId}`).toString();
    const option = (spanContext.traceFlags & TraceFlags.SAMPLED) === TraceFlags.SAMPLED ? '1' : '0';

    setter.set(carrier, CLOUD_TRACE_CONTEXT_HEADER, `${spanContext.traceId}/${spanId};o=${option}`);
  }

  extract(context: Context, carrier: unknown, getter: TextMapGetter<unknown>): Context {
    // A malformed upstream header must never fail a request, so every exit
    // returns the untouched context and the whole body is guarded.
    try {
      const raw = getter.get(carrier, CLOUD_TRACE_CONTEXT_HEADER);
      const value = Array.isArray(raw) ? raw[0] : raw;
      if (typeof value !== 'string' || value.length === 0) return context;

      const separator = value.indexOf('/');
      if (separator <= 0) return context;

      // Google documents the trace id as case-insensitive hex; W3C requires
      // lowercase. Normalising here is the deliberate asymmetry.
      const traceId = value.slice(0, separator).toLowerCase();
      if (!TRACE_ID_PATTERN.test(traceId) || !isValidTraceId(traceId)) return context;

      let remainder = value.slice(separator + 1);
      let sampled = false;

      const optionsAt = remainder.indexOf(';');
      if (optionsAt >= 0) {
        sampled = isSampled(remainder.slice(optionsAt + 1));
        remainder = remainder.slice(0, optionsAt);
      }

      if (!DECIMAL_PATTERN.test(remainder)) return context;

      const spanIdValue = BigInt(remainder);
      if (spanIdValue <= 0n || spanIdValue > MAX_UNSIGNED_64) return context;

      const spanId = spanIdValue.toString(16).padStart(16, '0');
      if (!isValidSpanId(spanId)) return context;

      return trace.setSpanContext(context, {
        traceId,
        spanId,
        traceFlags: sampled ? TraceFlags.SAMPLED : TraceFlags.NONE,
        isRemote: true,
      });
    } catch {
      return context;
    }
  }
}

/** Reads the `o=` option, tolerating other options alongside it. */
function isSampled(options: string): boolean {
  for (const option of options.split(';')) {
    const trimmed = option.trim();
    if (trimmed.startsWith('o=')) return trimmed.slice(2) === '1';
  }
  return false;
}
