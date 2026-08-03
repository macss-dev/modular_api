import {
  context as otelContext,
  propagation,
  SpanKind,
  SpanStatusCode,
  trace,
  type Span,
} from '@opentelemetry/api';

/** The header carrying a caller-supplied correlation id. */
export const REQUEST_ID_HEADER = 'x-request-id';

export interface ClientCallTracingInit {
  readonly method: string;
  readonly operationId: string;
  readonly url: string | URL;
  readonly headers: Record<string, string>;
}

/**
 * Instrumentation for one outbound call.
 *
 * **Zero configuration on purpose.** The parent comes from the ambient context — the
 * server span the host made active — and the tracer from the global provider. When no
 * OpenTelemetry SDK is registered both are no-ops, so a consumer who never enables tracing
 * gets no spans, no headers and no measurable cost. Nothing is threaded into
 * `ServiceClientConfig`.
 *
 * **Injection goes through the global propagator**, never a propagator of our own. This
 * package does not depend on `@macss/modular-api` (runbook D21), so it cannot reach the
 * framework's W3C propagator — and per the OpenTelemetry API's own guidance it should not:
 * instrumentation libraries read the global and leave setting it to the SDK or host. That
 * also means whatever chain the application configured is honoured here, including a Cloud
 * Trace propagator it appended, without this package knowing such a thing exists.
 *
 * The Dart counterpart is `lib/src/client_tracing.dart`.
 */
export class ClientCallTracing {
  private constructor(private readonly span: Span | undefined) {}

  /**
   * Starts a client span and injects trace context plus the caller's request id into
   * `headers`.
   */
  static start(init: ClientCallTracingInit, inboundRequestId?: string): ClientCallTracing {
    // Forwarded whether or not tracing is on. Envoy's tracing documentation lists
    // x-request-id propagation as an obligation separate from trace context, and it is the
    // one correlation header nearly every stack implements — so it survives a hop into a
    // service with no tracing at all (runbook D23). We forward, never invent: a chain with
    // no request id keeps having none.
    if (inboundRequestId !== undefined && inboundRequestId.length > 0) {
      init.headers[REQUEST_ID_HEADER] ??= inboundRequestId;
    }

    const parent = otelContext.active();
    const parentSpan = trace.getSpan(parent);

    // No recording parent means tracing is off for this request. A non-recording span and a
    // header nobody will read would be cost with no benefit.
    if (parentSpan === undefined || !parentSpan.isRecording()) {
      return new ClientCallTracing(undefined);
    }

    const target = safeUrl(init.url);

    const span = trace.getTracer('modular_api_rest_client').startSpan(
      // Semantic convention for a client span: the method, qualified by what was called.
      // The operation id is more useful than a bare method and safer than a full URL, which
      // can carry identifiers in its path.
      `${init.method} ${init.operationId}`,
      {
        kind: SpanKind.CLIENT,
        attributes: {
          'http.request.method': init.method,
          ...(target === undefined
            ? {}
            : {
                'server.address': target.hostname,
                ...(target.port === '' ? {} : { 'server.port': Number(target.port) }),
                'url.path': target.pathname,
              }),
        },
      },
      parent,
    );

    propagation.inject(trace.setSpan(parent, span), init.headers);

    return new ClientCallTracing(span);
  }

  /**
   * Ends the span, recording the outcome.
   *
   * `statusCode` is undefined when the call never produced a response — a timeout, a DNS
   * failure, a refused connection. That is always an error; a status code is an error at
   * 4xx and above, because a client span's failure is the *call* failing rather than the
   * server disagreeing.
   */
  complete({ statusCode, error }: { statusCode?: number; error?: unknown } = {}): void {
    const { span } = this;
    if (span === undefined) return;

    if (statusCode !== undefined) {
      span.setAttribute('http.response.status_code', statusCode);
    }

    if (error !== undefined) {
      span.recordException(error instanceof Error ? error : new Error(String(error)));
      span.setStatus({ code: SpanStatusCode.ERROR, message: 'request failed' });
    } else if (statusCode === undefined) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: 'no response' });
    } else if (statusCode >= 400) {
      // Unlike a server span, where 4xx is the caller's mistake, a 4xx here means *our*
      // outbound call failed. The distinction matters when reading a waterfall.
      span.setStatus({ code: SpanStatusCode.ERROR, message: `HTTP ${statusCode}` });
    }

    span.end();
  }
}

/** A malformed URL must not fail a request that is otherwise about to be made. */
function safeUrl(url: string | URL): URL | undefined {
  if (url instanceof URL) return url;
  try {
    return new URL(url);
  } catch {
    return undefined;
  }
}
