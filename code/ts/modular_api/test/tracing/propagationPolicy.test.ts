import {
  ROOT_CONTEXT,
  trace,
  type Context,
  type TextMapGetter,
  type TextMapPropagator,
  type TextMapSetter,
} from '@opentelemetry/api';
import { describe, expect, it } from 'vitest';

import {
  PropagationPolicy,
  REQUEST_ID_HEADER,
} from '../../src/core/tracing/propagationPolicy';
import {
  TRACEPARENT_HEADER,
  W3CTraceContextPropagator,
} from '../../src/core/tracing/w3cTraceContextPropagator';

/**
 * TypeScript mirror of `test/tracing/propagation_policy_test.dart`.
 *
 * The case table was reviewed once against the Dart version. This policy is ours —
 * no reference implementation exists anywhere — so the review gate stayed on for
 * Stage 3 where it was dropped for Stage 2.
 */
const TRACE_ID = '4bf92f3577b34da6a3ce929d0e0e4736';
const SPAN_ID = '00f067aa0ba902b7';
const TRACEPARENT = `00-${TRACE_ID}-${SPAN_ID}-01`;
const UUID = '3f2504e0-4f89-11d3-9a0c-0305e82c3301';

const spanContextOf = (context: Context) => trace.getSpanContext(context);

describe('PropagationPolicy defaults', () => {
  it('the default chain is W3C Trace Context alone', () => {
    // Not W3C plus Cloud Trace: a Google propagator in core would contradict
    // roadmap invariant 7. A service on Cloud Run appends one.
    const policy = new PropagationPolicy();

    expect(policy.propagators).toHaveLength(1);
    expect(policy.propagators[0]).toBeInstanceOf(W3CTraceContextPropagator);
  });

  it('incoming trace context is trusted by default', () => {
    expect(new PropagationPolicy().trustIncomingTraceContext).toBe(true);
  });
});

describe('resolution', () => {
  it('accepts a remote parent from traceparent', () => {
    const result = new PropagationPolicy().resolve({ [TRACEPARENT_HEADER]: TRACEPARENT });

    expect(result.hasRemoteParent).toBe(true);
    expect(spanContextOf(result.context)?.traceId).toBe(TRACE_ID);
    expect(spanContextOf(result.context)?.spanId).toBe(SPAN_ID);
    expect(spanContextOf(result.context)?.isRemote).toBe(true);
  });

  it('carries no span context when no propagator matches', () => {
    // The tracer generates ids for a root span. This class does not.
    const result = new PropagationPolicy().resolve({});

    expect(result.hasRemoteParent).toBe(false);
    expect(spanContextOf(result.context)).toBeUndefined();
  });

  it('carries no span context when the header is malformed', () => {
    const result = new PropagationPolicy().resolve({
      [TRACEPARENT_HEADER]: 'not-a-traceparent',
    });

    expect(result.hasRemoteParent).toBe(false);
  });

  it('resolves header names case-insensitively', () => {
    const result = new PropagationPolicy().resolve({ TraceParent: TRACEPARENT });

    expect(result.hasRemoteParent).toBe(true);
  });
});

describe('chain order (D24)', () => {
  it('the first propagator to yield a valid context wins', () => {
    const policy = new PropagationPolicy({
      propagators: [
        new FixedPropagator('a'.repeat(32)),
        new FixedPropagator('b'.repeat(32)),
      ],
    });

    expect(spanContextOf(policy.resolve({}).context)?.traceId).toBe('a'.repeat(32));
  });

  it('falls through to the next propagator when the first yields nothing', () => {
    const policy = new PropagationPolicy({
      propagators: [new NeverMatchesPropagator(), new W3CTraceContextPropagator()],
    });

    const result = policy.resolve({ [TRACEPARENT_HEADER]: TRACEPARENT });

    expect(spanContextOf(result.context)?.traceId).toBe(TRACE_ID);
  });

  it('a propagator that throws does not break resolution', () => {
    // A third-party propagator is not our code. One misbehaving entry must not fail
    // a request; the chain continues.
    const policy = new PropagationPolicy({
      propagators: [new ThrowingPropagator(), new W3CTraceContextPropagator()],
    });

    const result = policy.resolve({ [TRACEPARENT_HEADER]: TRACEPARENT });

    expect(spanContextOf(result.context)?.traceId).toBe(TRACE_ID);
  });

  it('an empty chain resolves to a context with no span context', () => {
    const policy = new PropagationPolicy({ propagators: [] });

    expect(policy.resolve({ [TRACEPARENT_HEADER]: TRACEPARENT }).hasRemoteParent).toBe(false);
  });
});

describe('X-Request-ID is preserved, never adopted (D6)', () => {
  it('is exposed as requestId', () => {
    expect(new PropagationPolicy().resolve({ [REQUEST_ID_HEADER]: UUID }).requestId).toBe(UUID);
  });

  it('is undefined when the caller sent none', () => {
    expect(new PropagationPolicy().resolve({}).requestId).toBeUndefined();
  });

  it('never becomes the trace id, even when it is a valid UUID', () => {
    // Stripping the dashes from a v4 UUID would produce a structurally valid trace
    // id, which is exactly why this needs asserting rather than assuming.
    const result = new PropagationPolicy().resolve({ [REQUEST_ID_HEADER]: UUID });

    expect(result.hasRemoteParent).toBe(false);
    expect(spanContextOf(result.context)).toBeUndefined();
  });

  it('does not override a trace id that arrived in traceparent', () => {
    const result = new PropagationPolicy().resolve({
      [TRACEPARENT_HEADER]: TRACEPARENT,
      [REQUEST_ID_HEADER]: UUID,
    });

    expect(spanContextOf(result.context)?.traceId).toBe(TRACE_ID);
    expect(result.requestId).toBe(UUID);
  });

  it('a non-UUID value is preserved verbatim', () => {
    // We do not validate the caller's correlation token. It is opaque to us.
    const result = new PropagationPolicy().resolve({
      [REQUEST_ID_HEADER]: 'order-42/retry-3',
    });

    expect(result.requestId).toBe('order-42/retry-3');
  });

  it('the same request id twice does not produce one shared trace', () => {
    // The retry case that motivated reversing D6: callers reuse X-Request-ID
    // deliberately as an idempotency key, so adopting it would merge unrelated
    // retries into a single trace with several unconnected trees.
    const policy = new PropagationPolicy();

    const first = policy.resolve({ [REQUEST_ID_HEADER]: UUID });
    const second = policy.resolve({ [REQUEST_ID_HEADER]: UUID });

    expect(first.hasRemoteParent).toBe(false);
    expect(second.hasRemoteParent).toBe(false);
    expect(first.requestId).toBe(second.requestId);
  });
});

describe('trustIncomingTraceContext (D25)', () => {
  it('when false, an incoming traceparent is ignored', () => {
    const policy = new PropagationPolicy({ trustIncomingTraceContext: false });

    const result = policy.resolve({ [TRACEPARENT_HEADER]: TRACEPARENT });

    expect(result.hasRemoteParent).toBe(false);
    expect(spanContextOf(result.context)).toBeUndefined();
  });

  it('when false, every propagator in the chain is skipped', () => {
    const policy = new PropagationPolicy({
      trustIncomingTraceContext: false,
      propagators: [new FixedPropagator(TRACE_ID)],
    });

    expect(policy.resolve({}).hasRemoteParent).toBe(false);
  });

  it('when false, X-Request-ID is still preserved', () => {
    // It was never trusted as identity, so there is nothing to distrust. Log
    // correlation and outbound forwarding (D23) keep working either way.
    const policy = new PropagationPolicy({ trustIncomingTraceContext: false });

    expect(policy.resolve({ [REQUEST_ID_HEADER]: 'order-42' }).requestId).toBe('order-42');
  });
});

describe('resolution allocates no span (D7, G3)', () => {
  it('a resolved remote parent records nothing', () => {
    // The intent of D7 is that resolution creates no *recording* span: only the
    // middleware does that, and only when tracing is configured.
    //
    // How that is asserted differs by API, and the difference is real rather than
    // cosmetic. Dart keeps SpanContext and Span as separate context keys, so there
    // `context.span` is null. This API has no separate span-context key: setting a
    // span context wraps it in a NonRecordingSpan and installs that as the span, and
    // Python does the same explicitly. So the portable assertion is "nothing is
    // recording", not "no span object exists".
    const result = new PropagationPolicy().resolve({ [TRACEPARENT_HEADER]: TRACEPARENT });

    expect(trace.getSpanContext(result.context)).toBeDefined();
    expect(trace.getSpan(result.context)?.isRecording()).toBe(false);
  });

  it('an unmatched resolution holds neither', () => {
    const result = new PropagationPolicy().resolve({});

    expect(trace.getSpanContext(result.context)).toBeUndefined();
    expect(trace.getSpan(result.context)).toBeUndefined();
  });
});

/** Always yields the same span context, regardless of the carrier. */
class FixedPropagator implements TextMapPropagator<unknown> {
  constructor(private readonly traceId: string) {}

  fields(): string[] {
    return [];
  }

  inject(): void {}

  extract(context: Context): Context {
    return trace.setSpanContext(context, {
      traceId: this.traceId,
      spanId: SPAN_ID,
      traceFlags: 1,
      isRemote: true,
    });
  }
}

/** Never yields anything, like a propagator whose header is absent. */
class NeverMatchesPropagator implements TextMapPropagator<unknown> {
  fields(): string[] {
    return [];
  }

  inject(): void {}

  extract(context: Context): Context {
    return context;
  }
}

/** Misbehaves, to prove the chain survives a third party's bug. */
class ThrowingPropagator implements TextMapPropagator<unknown> {
  fields(): string[] {
    return [];
  }

  inject(): void {}

  extract(): Context {
    throw new Error('a third-party propagator threw');
  }
}

// Referenced so the unused-import lint stays quiet about the setter type the
// TextMapPropagator interface mentions but these fakes never use.
export type _Unused = TextMapGetter<unknown> | TextMapSetter<unknown> | typeof ROOT_CONTEXT;
