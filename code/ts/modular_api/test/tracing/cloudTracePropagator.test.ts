import { ROOT_CONTEXT, TraceFlags, trace, type Context, type TextMapGetter, type TextMapSetter } from '@opentelemetry/api';
import { describe, expect, it } from 'vitest';

import {
  CLOUD_TRACE_CONTEXT_HEADER,
  CloudTraceContextPropagator,
} from '../../src/core/tracing/cloudTracePropagator';

/**
 * TypeScript mirror of `test/tracing/cloud_trace_propagator_test.dart`.
 *
 * The case table was reviewed once, against the Dart version, and is repeated
 * here rather than re-derived — same names, same expectations. What differs is
 * idiom: this API's getter and setter take the carrier as a parameter instead of
 * holding it, `get` may return `string | string[]`, and trace/span ids are plain
 * strings rather than value objects.
 *
 * The case that justified the review gate is `SPAN_ID`: Google encodes it in
 * decimal while every other id in tracing is hex. Here it is doubly relevant,
 * because JavaScript's Number cannot represent 2^64-1 at all.
 */
const TRACE_ID = '4bf92f3577b34da6a3ce929d0e0e4736';

const propagator = new CloudTraceContextPropagator();

/** A carrier reader with HTTP semantics: header names are case-insensitive. */
const headerGetter: TextMapGetter<Record<string, string>> = {
  keys: (carrier) => Object.keys(carrier),
  get: (carrier, key) => {
    const wanted = key.toLowerCase();
    const found = Object.entries(carrier).find(([name]) => name.toLowerCase() === wanted);
    return found?.[1];
  },
};

const headerSetter: TextMapSetter<Record<string, string>> = {
  set: (carrier, key, value) => {
    carrier[key] = value;
  },
};

const extractFrom = (carrier: Record<string, string>): Context =>
  propagator.extract(ROOT_CONTEXT, carrier, headerGetter as TextMapGetter<unknown>);

const extract = (headerValue: string): Context =>
  extractFrom({ [CLOUD_TRACE_CONTEXT_HEADER]: headerValue });

const injectFrom = (spanContext: Parameters<typeof trace.setSpanContext>[1]): Record<string, string> => {
  const carrier: Record<string, string> = {};
  propagator.inject(
    trace.setSpanContext(ROOT_CONTEXT, spanContext),
    carrier,
    headerSetter as TextMapSetter<unknown>,
  );
  return carrier;
};

describe('CloudTraceContextPropagator', () => {
  it('advertises the single carrier key it reads and writes', () => {
    expect(propagator.fields()).toEqual([CLOUD_TRACE_CONTEXT_HEADER]);
  });

  it('extracts a 32-hex trace id and a decimal span id', () => {
    const spanContext = trace.getSpanContext(extract(`${TRACE_ID}/1;o=1`));

    expect(spanContext).toBeDefined();
    expect(spanContext?.traceId).toBe(TRACE_ID);
    expect(spanContext?.spanId).toBe('0000000000000001');
  });

  it('reads the span id as decimal, not hex', () => {
    // 1234567890 decimal is 0x499602D2. Read as hex it would be 0x1234567890 ->
    // '0000001234567890', which is the bug this asserts against.
    const spanContext = trace.getSpanContext(extract(`${TRACE_ID}/1234567890;o=1`));

    expect(spanContext?.spanId).toBe('00000000499602d2');
    expect(spanContext?.spanId).not.toBe('0000001234567890');
  });

  it('handles a span id at the top of the unsigned 64-bit range', () => {
    // 2^64-1. Number cannot represent this, so the conversion must use BigInt.
    const spanContext = trace.getSpanContext(extract(`${TRACE_ID}/18446744073709551615;o=1`));

    expect(spanContext?.spanId).toBe('ffffffffffffffff');
  });

  it('treats o=1 as sampled and o=0 as not sampled', () => {
    expect(trace.getSpanContext(extract(`${TRACE_ID}/1;o=1`))?.traceFlags).toBe(TraceFlags.SAMPLED);
    expect(trace.getSpanContext(extract(`${TRACE_ID}/1;o=0`))?.traceFlags).toBe(TraceFlags.NONE);
  });

  it('defaults to not sampled when the ;o= segment is absent', () => {
    const spanContext = trace.getSpanContext(extract(`${TRACE_ID}/1`));

    expect(spanContext).toBeDefined();
    expect(spanContext?.traceFlags).toBe(TraceFlags.NONE);
  });

  it('accepts a case-insensitive trace id and normalises it to lowercase', () => {
    const spanContext = trace.getSpanContext(extract(`${TRACE_ID.toUpperCase()}/1;o=1`));

    expect(spanContext?.traceId).toBe(TRACE_ID);
  });

  it('marks an extracted span context as remote', () => {
    expect(trace.getSpanContext(extract(`${TRACE_ID}/1;o=1`))?.isRemote).toBe(true);
  });

  describe('leaves the context untouched rather than throwing', () => {
    it('when the header is absent', () => {
      expect(trace.getSpanContext(extractFrom({}))).toBeUndefined();
    });

    const malformed: Record<string, string> = {
      'no span id segment': TRACE_ID,
      'empty span id': `${TRACE_ID}/`,
      'non-numeric span id': `${TRACE_ID}/abc`,
      'span id beyond 64 bits': `${TRACE_ID}/18446744073709551616`,
      'short trace id': 'abc/1',
      'non-hex trace id': `${'z'.repeat(32)}/1`,
      'all-zero trace id': `${'0'.repeat(32)}/1`,
      'all-zero span id': `${TRACE_ID}/0`,
      'empty value': '',
      'unrelated garbage': 'not-a-trace-context',
    };

    for (const [label, value] of Object.entries(malformed)) {
      it(`on ${label}`, () => {
        expect(trace.getSpanContext(extract(value))).toBeUndefined();
      });
    }
  });

  it("injects the header back in Google's format", () => {
    const carrier = injectFrom({
      traceId: TRACE_ID,
      spanId: '00000000499602d2',
      traceFlags: TraceFlags.SAMPLED,
    });

    expect(carrier[CLOUD_TRACE_CONTEXT_HEADER]).toBe(`${TRACE_ID}/1234567890;o=1`);
  });

  it('injects o=0 for a non-sampled span context', () => {
    const carrier = injectFrom({
      traceId: TRACE_ID,
      spanId: '0000000000000001',
      traceFlags: TraceFlags.NONE,
    });

    expect(carrier[CLOUD_TRACE_CONTEXT_HEADER]).toBe(`${TRACE_ID}/1;o=0`);
  });

  it('injects nothing when there is no span context to propagate', () => {
    const carrier: Record<string, string> = {};
    propagator.inject(ROOT_CONTEXT, carrier, headerSetter as TextMapSetter<unknown>);

    expect(carrier).toEqual({});
  });

  it('round-trips a value it produced', () => {
    const original = {
      traceId: TRACE_ID,
      spanId: '00000000499602d2',
      traceFlags: TraceFlags.SAMPLED,
    };

    const extracted = trace.getSpanContext(extractFrom(injectFrom(original)));

    expect(extracted?.traceId).toBe(original.traceId);
    expect(extracted?.spanId).toBe(original.spanId);
    expect(extracted?.traceFlags).toBe(TraceFlags.SAMPLED);
  });
});
