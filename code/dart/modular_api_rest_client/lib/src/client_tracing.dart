import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';

/// The header carrying a caller-supplied correlation id.
const String requestIdHeader = 'x-request-id';

/// Instrumentation for one outbound call.
///
/// **Zero configuration on purpose.** The parent comes from the ambient context — the
/// server span the host made active — and the tracer comes from the global provider.
/// When no OpenTelemetry SDK is installed both are no-ops, so a consumer who never
/// enables tracing gets no spans, no headers and no measurable cost. Nothing has to be
/// wired into `ServiceClientConfig`.
///
/// **Injection goes through the global propagator**, never through a propagator of our
/// own. This package does not depend on `modular_api` (runbook D21), so it cannot reach
/// the framework's W3C propagator — and it should not: the OpenTelemetry API's own
/// documentation says instrumentation libraries should *read* the global propagator and
/// leave setting it to the SDK or the host. That also means whatever chain the
/// application configured is honoured here, including a Cloud Trace propagator it
/// appended, without this package knowing such a thing exists.
class ClientCallTracing {
  ClientCallTracing._(this._span);

  final APISpan? _span;

  /// Starts a client span for [operationId] against [uri], and injects trace context
  /// plus the caller's request id into [headers].
  ///
  /// Returns a handle whose [complete] must be called exactly once.
  static ClientCallTracing start({
    required String method,
    required String operationId,
    required Uri uri,
    required Map<String, String> headers,
    String? inboundRequestId,
  }) {
    // Forwarded whether or not tracing is on. Envoy's tracing documentation lists
    // x-request-id propagation as a separate obligation from trace context, and it is the
    // one correlation header nearly every stack implements — so it survives a hop into a
    // service that has no tracing at all (runbook D23). We forward, never invent: a chain
    // that has no request id keeps having none.
    if (inboundRequestId != null && inboundRequestId.isNotEmpty) {
      headers.putIfAbsent(requestIdHeader, () => inboundRequestId);
    }

    final parent = Context.current;
    final parentSpan = parent.span;

    // No recording parent means tracing is off for this request. Creating a
    // non-recording span and injecting a header nobody will read would be cost with no
    // benefit.
    if (parentSpan == null || !parentSpan.spanContext.isValid) {
      return ClientCallTracing._(null);
    }

    final span = OTelAPI.tracerProvider().getTracer('modular_api_rest_client').startSpan(
      // Semantic convention for a client span: the method, qualified by what was called.
      // The operation id is more useful than a bare method and safer than a full URL,
      // which can carry identifiers in its path.
      '$method $operationId',
      context: parent,
      kind: SpanKind.client,
      attributes: OTelAPI.attributesFromMap(<String, Object>{
        'http.request.method': method,
        'server.address': uri.host,
        if (uri.hasPort) 'server.port': uri.port,
        'url.path': uri.path,
      }),
    );

    OTelAPI.textMapPropagator.inject(
      parent.withSpanContext(span.spanContext),
      headers,
      _MapSetter(headers),
    );

    return ClientCallTracing._(span);
  }

  /// Ends the span, recording the outcome.
  ///
  /// [statusCode] is null when the call never produced a response — a timeout, a DNS
  /// failure, a refused connection. That case is always an error; a status code is only
  /// an error at 4xx and above, because a client span's failure is the *call* failing,
  /// not the server disagreeing.
  void complete({int? statusCode, Object? error}) {
    final span = _span;
    if (span == null) return;

    if (statusCode != null) {
      span.setIntAttribute('http.response.status_code', statusCode);
    }

    if (error != null) {
      span.recordException(error);
      span.setStatus(SpanStatusCode.Error, error.runtimeType.toString());
    } else if (statusCode == null) {
      span.setStatus(SpanStatusCode.Error, 'no response');
    } else if (statusCode >= 400) {
      // Unlike a server span, where 4xx is the caller's mistake, a 4xx here means *our*
      // outbound call failed. The distinction matters when reading a waterfall.
      span.setStatus(SpanStatusCode.Error, 'HTTP $statusCode');
    }

    span.end();
  }
}

class _MapSetter extends TextMapSetter<String> {
  _MapSetter(this._headers);

  final Map<String, String> _headers;

  @override
  void set(String key, String value) => _headers[key] = value;
}
