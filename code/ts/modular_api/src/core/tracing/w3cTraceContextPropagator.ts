import {
  createTraceState,
  isValidSpanId,
  isValidTraceId,
  TraceFlags,
  trace,
  type Context,
  type TextMapGetter,
  type TextMapPropagator,
  type TextMapSetter,
} from '@opentelemetry/api';

/** The W3C `traceparent` carrier key. */
export const TRACEPARENT_HEADER = 'traceparent';

/** The W3C `tracestate` carrier key. */
export const TRACESTATE_HEADER = 'tracestate';

/** The only version currently defined by the W3C Trace Context recommendation. */
const SUPPORTED_VERSION = '00';

/** Reserved by the specification and never valid. */
const FORBIDDEN_VERSION = 'ff';

/**
 * The 55 characters every version must begin with:
 * `<version>-<32 hex>-<16 hex>-<2 hex>`, lowercase only, fixed-width fields.
 *
 * Deliberately **not** anchored at the end. A future version may append fields, and
 * the specification requires parsing the known prefix rather than rejecting the
 * header — see `extract`.
 */
const TRACEPARENT_PATTERN = /^([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})/;

/**
 * Propagates W3C Trace Context: `traceparent` and `tracestate`.
 *
 * This is ours because `@opentelemetry/api` does not ship a propagator — the W3C
 * implementation lives in `@opentelemetry/core`, which is past the API boundary
 * that ADR-0005 A2 draws and which the Stage 1b dependency guard forbids
 * (runbook D26). Python's official API package includes an equivalent, and that
 * implementation is the reference these cases are checked against.
 *
 * The format is exact: 55 characters, `00-<trace id>-<parent span id>-<flags>`,
 * lowercase hex only, version `00` the only one defined. Anything else is
 * rejected, and rejection means *return the context unchanged* — a broken header
 * from an upstream caller must never fail a request.
 *
 * `tracestate` is carried verbatim and never interpreted (runbook D4). This
 * implementation is more faithful to that than the Dart one can be: the
 * JavaScript API's `createTraceState` accepts the raw header string, so ordering
 * and formatting survive untouched, whereas the Dart API only accepts a map.
 *
 * The Dart counterpart is `lib/src/core/tracing/w3c_trace_context_propagator.dart`.
 */
export class W3CTraceContextPropagator implements TextMapPropagator<unknown> {
  fields(): string[] {
    return [TRACEPARENT_HEADER, TRACESTATE_HEADER];
  }

  inject(context: Context, carrier: unknown, setter: TextMapSetter<unknown>): void {
    const spanContext = trace.getSpanContext(context);
    if (spanContext === undefined) return;
    if (!isValidTraceId(spanContext.traceId) || !isValidSpanId(spanContext.spanId)) return;

    const flags = (spanContext.traceFlags & TraceFlags.SAMPLED) === TraceFlags.SAMPLED ? '01' : '00';
    setter.set(
      carrier,
      TRACEPARENT_HEADER,
      `${SUPPORTED_VERSION}-${spanContext.traceId}-${spanContext.spanId}-${flags}`,
    );

    // Only when there is something to carry. An empty tracestate is a header that
    // says nothing.
    const serialized = spanContext.traceState?.serialize();
    if (serialized !== undefined && serialized.length > 0) {
      setter.set(carrier, TRACESTATE_HEADER, serialized);
    }
  }

  extract(context: Context, carrier: unknown, getter: TextMapGetter<unknown>): Context {
    try {
      const raw = first(getter.get(carrier, TRACEPARENT_HEADER));
      if (raw === undefined || raw.length === 0) return context;

      const match = TRACEPARENT_PATTERN.exec(raw);
      if (match === null) return context;

      const [matched, version, traceId, spanId, flagsHex] = match;

      // `ff` is reserved and never valid.
      if (version === FORBIDDEN_VERSION) return context;

      // A *future* version must be parsed, not rejected: the specification says an
      // implementation should read the known 55-character prefix and ignore what
      // follows. Rejecting it would mean that the day W3C publishes version 01,
      // every service running this code silently stops honouring incoming trace
      // context — the failure would look like tracing simply not working.
      //
      // Verified against the official Python implementation, which accepts `01-…`
      // and `01-…-extra` and rejects `00-…-extra`.
      if (version === SUPPORTED_VERSION) {
        // Version 00 is exactly 55 characters; trailing data is malformed.
        if (raw.length !== matched.length) return context;
      } else if (raw.length > matched.length && raw[matched.length] !== '-') {
        // A newer version's extra fields must be delimited.
        return context;
      }

      if (!isValidTraceId(traceId) || !isValidSpanId(spanId)) return context;

      // Bit 0 is `sampled`. Unknown bits must not defeat the one we understand.
      const flags = Number.parseInt(flagsHex, 16);
      const sampled = (flags & TraceFlags.SAMPLED) === TraceFlags.SAMPLED;

      const rawState = first(getter.get(carrier, TRACESTATE_HEADER));

      return trace.setSpanContext(context, {
        traceId,
        spanId,
        traceFlags: sampled ? TraceFlags.SAMPLED : TraceFlags.NONE,
        isRemote: true,
        // Verbatim: the raw header goes in untouched (D4).
        traceState:
          rawState !== undefined && rawState.trim().length > 0
            ? createTraceState(rawState)
            : undefined,
      });
    } catch {
      return context;
    }
  }
}

/** This API's getter may return a single value or a list. */
function first(value: undefined | string | string[]): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}
