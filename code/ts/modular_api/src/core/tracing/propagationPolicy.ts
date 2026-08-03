import {
  ROOT_CONTEXT,
  trace,
  type Context,
  type SpanContext,
  type TextMapGetter,
  type TextMapPropagator,
} from '@opentelemetry/api';

import { W3CTraceContextPropagator } from './w3cTraceContextPropagator';

/**
 * The header carrying a caller-supplied correlation id.
 *
 * Read and preserved, **never** adopted as the trace id — see {@link PropagationPolicy}.
 */
export const REQUEST_ID_HEADER = 'x-request-id';

/** What resolving the incoming headers produced. */
export interface PropagationResult {
  /**
   * The context to continue with. Carries a remote parent when one was accepted,
   * and otherwise carries none — trace and span id generation belongs to the
   * tracer, not here.
   */
  readonly context: Context;

  /**
   * The caller's `X-Request-ID`, when it sent one. Preserved for log correlation
   * and for forwarding on outbound calls; it is not identity.
   */
  readonly requestId?: string;

  /** Whether a remote parent was accepted from the incoming headers. */
  readonly hasRemoteParent: boolean;
}

export interface PropagationPolicyOptions {
  /** The ordered chain. First valid span context wins. Defaults to W3C alone. */
  readonly propagators?: readonly TextMapPropagator<unknown>[];

  /** Whether an incoming trace context is honoured at all. Defaults to `true`. */
  readonly trustIncomingTraceContext?: boolean;
}

/**
 * Resolves incoming request headers into a tracing context.
 *
 * **Composable rather than hardcoded** (runbook D24). The chain is an ordered list
 * of propagators and the first to yield a valid span context wins. The default is
 * W3C Trace Context only: a service on Google Cloud appends a Cloud Trace
 * propagator, which keeps anything vendor-specific out of the framework. A service
 * behind a B3-speaking mesh appends a B3 propagator the same way, instead of forking.
 *
 * **`X-Request-ID` is never the trace id** (runbook D6). It is read and preserved
 * beside the trace id, never promoted into it: callers reuse it deliberately on
 * retries, so adopting it would merge unrelated retries into one trace; any client
 * could then collide traces on purpose; and `trace_id` would have ambiguous
 * provenance, sometimes caller-supplied and sometimes generated.
 *
 * **Nothing is generated here.** When no propagator matches, the returned context
 * simply carries no span context and the tracer starts a fresh trace with ids of its
 * own (runbook D7, gate G3).
 *
 * The Dart counterpart is `lib/src/core/tracing/propagation_policy.dart`.
 */
export class PropagationPolicy {
  /** The ordered chain. First valid span context wins. */
  readonly propagators: readonly TextMapPropagator<unknown>[];

  /**
   * Whether an incoming trace context is honoured at all (D25).
   *
   * Defaults to `true`, matching every official OpenTelemetry SDK. Set it to
   * `false` on a service that receives internet traffic directly, where a caller
   * could otherwise choose its trace ids.
   */
  readonly trustIncomingTraceContext: boolean;

  constructor(options: PropagationPolicyOptions = {}) {
    this.propagators = options.propagators ?? [new W3CTraceContextPropagator()];
    this.trustIncomingTraceContext = options.trustIncomingTraceContext ?? true;
  }

  /** Resolves `headers` into a context plus the preserved request id. */
  resolve(headers: Record<string, string>): PropagationResult {
    // Read first and unconditionally: the request id is preserved whether or not
    // incoming trace context is trusted, because it was never trusted as identity.
    const requestId = headerValue(headers, REQUEST_ID_HEADER);

    if (!this.trustIncomingTraceContext) {
      return { context: ROOT_CONTEXT, requestId, hasRemoteParent: false };
    }

    const getter = caseInsensitiveGetter;

    for (const propagator of this.propagators) {
      try {
        const resolved = propagator.extract(ROOT_CONTEXT, headers, getter);
        if (isValid(trace.getSpanContext(resolved))) {
          // First valid wins (D24).
          return { context: resolved, requestId, hasRemoteParent: true };
        }
      } catch {
        // A third-party propagator is not our code, and one misbehaving entry must
        // not fail a request. Move on to the next.
        continue;
      }
    }

    // No parent accepted. The tracer starts a fresh trace and generates its own
    // ids — nothing is generated here, which is what keeps this allocation-free.
    return { context: ROOT_CONTEXT, requestId, hasRemoteParent: false };
  }
}

function isValid(spanContext: SpanContext | undefined): boolean {
  return spanContext !== undefined && trace.isSpanContextValid(spanContext);
}

/** Reads a header case-insensitively, as HTTP requires. */
function headerValue(headers: Record<string, string>, name: string): string | undefined {
  const wanted = name.toLowerCase();
  return Object.entries(headers).find(([key]) => key.toLowerCase() === wanted)?.[1];
}

/**
 * Carrier reader with HTTP semantics.
 *
 * Header casing belongs to the carrier rather than to any propagator, so it is
 * handled once here instead of in each of them.
 */
const caseInsensitiveGetter: TextMapGetter<unknown> = {
  keys: (carrier) => Object.keys(carrier as Record<string, string>),
  get: (carrier, key) => headerValue(carrier as Record<string, string>, key),
};
