import {
  createTraceState,
  ROOT_CONTEXT,
  TraceFlags,
  trace,
  type Context,
  type SpanContext,
  type TextMapGetter,
  type TextMapSetter,
} from '@opentelemetry/api';
import { describe, expect, it } from 'vitest';

import {
  TRACEPARENT_HEADER,
  TRACESTATE_HEADER,
  W3CTraceContextPropagator,
} from '../../src/core/tracing/w3cTraceContextPropagator';

/**
 * TypeScript mirror of `test/tracing/w3c_trace_context_propagator_test.dart`.
 * Same case names, same expectations; the reference both are checked against is
 * Python's official implementation (runbook D26).
 */
const TRACE_ID = '4bf92f3577b34da6a3ce929d0e0e4736';
const SPAN_ID = '00f067aa0ba902b7';
const SAMPLED = `00-${TRACE_ID}-${SPAN_ID}-01`;

const propagator = new W3CTraceContextPropagator();

/** A carrier reader with HTTP semantics: header names are case-insensitive. */
const headerGetter: TextMapGetter<Record<string, string>> = {
  keys: (carrier) => Object.keys(carrier),
  get: (carrier, key) => {
    const wanted = key.toLowerCase();
    return Object.entries(carrier).find(([name]) => name.toLowerCase() === wanted)?.[1];
  },
};

const headerSetter: TextMapSetter<Record<string, string>> = {
  set: (carrier, key, value) => {
    carrier[key] = value;
  },
};

const extractFrom = (carrier: Record<string, string>): Context =>
  propagator.extract(ROOT_CONTEXT, carrier, headerGetter as TextMapGetter<unknown>);

const extract = (traceparent: string): Context =>
  extractFrom({ [TRACEPARENT_HEADER]: traceparent });

const inject = (spanContext: SpanContext): Record<string, string> => {
  const carrier: Record<string, string> = {};
  propagator.inject(
    trace.setSpanContext(ROOT_CONTEXT, spanContext),
    carrier,
    headerSetter as TextMapSetter<unknown>,
  );
  return carrier;
};

describe('W3CTraceContextPropagator', () => {
  it('advertises traceparent and tracestate as its fields', () => {
    expect(propagator.fields()).toEqual([TRACEPARENT_HEADER, TRACESTATE_HEADER]);
  });

  it('extracts trace id, parent span id and the sampled flag', () => {
    const spanContext = trace.getSpanContext(extract(SAMPLED));

    expect(spanContext).toBeDefined();
    expect(spanContext?.traceId).toBe(TRACE_ID);
    expect(spanContext?.spanId).toBe(SPAN_ID);
    expect(spanContext?.traceFlags).toBe(TraceFlags.SAMPLED);
  });

  it('marks an extracted span context as remote', () => {
    expect(trace.getSpanContext(extract(SAMPLED))?.isRemote).toBe(true);
  });

  it('reads the sampled flag from bit 0 of the flags byte', () => {
    expect(trace.getSpanContext(extract(`00-${TRACE_ID}-${SPAN_ID}-01`))?.traceFlags).toBe(
      TraceFlags.SAMPLED,
    );
    expect(trace.getSpanContext(extract(`00-${TRACE_ID}-${SPAN_ID}-00`))?.traceFlags).toBe(
      TraceFlags.NONE,
    );
    // Unknown flags must not defeat the bit we do understand.
    expect(
      (trace.getSpanContext(extract(`00-${TRACE_ID}-${SPAN_ID}-03`))?.traceFlags ?? 0) &
        TraceFlags.SAMPLED,
    ).toBe(TraceFlags.SAMPLED);
  });

  describe('carries tracestate', () => {
    it('verbatim, preserving order', () => {
      // W3C makes tracestate ordering significant: the leftmost entry is the most
      // recently updated system. This API keeps the raw string, so order survives.
      const raw = 'rojo=00f067aa0ba902b7,congo=t61rcWkgMzE';
      const spanContext = trace.getSpanContext(
        extractFrom({ [TRACEPARENT_HEADER]: SAMPLED, [TRACESTATE_HEADER]: raw }),
      );

      expect(spanContext?.traceState?.serialize()).toBe(raw);
    });

    it('tolerating its absence', () => {
      expect(trace.getSpanContext(extract(SAMPLED))?.traceState).toBeUndefined();
    });
  });

  describe('leaves the context untouched rather than throwing', () => {
    it('when the header is absent', () => {
      expect(trace.getSpanContext(extractFrom({}))).toBeUndefined();
    });

    const malformed: Record<string, string> = {
      'unsupported version 01': `01-${TRACE_ID}-${SPAN_ID}-01`,
      'unsupported version ff': `ff-${TRACE_ID}-${SPAN_ID}-01`,
      'short trace id': `00-abc-${SPAN_ID}-01`,
      'short span id': `00-${TRACE_ID}-abc-01`,
      'missing flags field': `00-${TRACE_ID}-${SPAN_ID}`,
      'extra field': `00-${TRACE_ID}-${SPAN_ID}-01-extra`,
      'non-hex trace id': `00-${'z'.repeat(32)}-${SPAN_ID}-01`,
      'non-hex flags': `00-${TRACE_ID}-${SPAN_ID}-zz`,
      'uppercase hex': `00-${TRACE_ID.toUpperCase()}-${SPAN_ID}-01`,
      'all-zero trace id': `00-${'0'.repeat(32)}-${SPAN_ID}-01`,
      'all-zero span id': `00-${TRACE_ID}-${'0'.repeat(16)}-01`,
      'empty value': '',
      'unrelated garbage': 'not-a-traceparent',
    };

    for (const [label, value] of Object.entries(malformed)) {
      it(`on ${label}`, () => {
        expect(trace.getSpanContext(extract(value))).toBeUndefined();
      });
    }
  });

  it('injects a valid traceparent', () => {
    const carrier = inject({ traceId: TRACE_ID, spanId: SPAN_ID, traceFlags: TraceFlags.SAMPLED });

    expect(carrier[TRACEPARENT_HEADER]).toBe(SAMPLED);
  });

  it('injects flags 00 for a non-sampled span context', () => {
    const carrier = inject({ traceId: TRACE_ID, spanId: SPAN_ID, traceFlags: TraceFlags.NONE });

    expect(carrier[TRACEPARENT_HEADER]).toBe(`00-${TRACE_ID}-${SPAN_ID}-00`);
  });

  it('injects tracestate only when one was received', () => {
    const without = inject({ traceId: TRACE_ID, spanId: SPAN_ID, traceFlags: TraceFlags.NONE });
    expect(without[TRACESTATE_HEADER]).toBeUndefined();

    const withState = inject({
      traceId: TRACE_ID,
      spanId: SPAN_ID,
      traceFlags: TraceFlags.SAMPLED,
      traceState: createTraceState('rojo=00f067aa0ba902b7'),
    });
    expect(withState[TRACESTATE_HEADER]).toBe('rojo=00f067aa0ba902b7');
  });

  it('injects nothing when there is no span context to propagate', () => {
    const carrier: Record<string, string> = {};
    propagator.inject(ROOT_CONTEXT, carrier, headerSetter as TextMapSetter<unknown>);

    expect(carrier).toEqual({});
  });

  it('round-trips a value it produced', () => {
    const original: SpanContext = {
      traceId: TRACE_ID,
      spanId: SPAN_ID,
      traceFlags: TraceFlags.SAMPLED,
    };

    const extracted = trace.getSpanContext(extractFrom(inject(original)));

    expect(extracted?.traceId).toBe(original.traceId);
    expect(extracted?.spanId).toBe(original.spanId);
    expect(extracted?.traceFlags).toBe(TraceFlags.SAMPLED);
  });
});
