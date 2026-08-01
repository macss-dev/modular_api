import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';

import 'propagation_policy.dart';

/// The server span for one inbound call, plus what propagation resolved.
final class ServerSpanStart {
  const ServerSpanStart({required this.span, required this.propagation});

  final APISpan span;
  final PropagationResult propagation;
}

/// Opens a server span for one inbound call.
///
/// **Deliberately transport-neutral** (gate G4). Nothing in this file mentions HTTP, shelf, or a
/// request object: it takes a method, a route and a header map, which is all any transport can
/// supply. `tracingMiddleware` is a thin adapter from shelf to this, and the planned gRPC transport
/// arrives the same way — as another adapter, not as a second copy of span construction.
///
/// This was extracted when G4 was checked rather than assumed. The span had been built inline inside
/// the middleware's shelf closure, which satisfied every behavioural test and would have forced a
/// gRPC transport to duplicate it.
ServerSpanStart startServerSpan({
  required APITracer tracer,
  required String method,
  required String route,
  required Map<String, String> headers,
  PropagationPolicy policy = const PropagationPolicy(),
}) {
  final normalizedMethod = method.toUpperCase();
  final resolved = policy.resolve(headers);

  final span = tracer.startSpan(
    // Semantic convention for a server span: method then route.
    '$normalizedMethod $route',
    // `context` supplies the PARENT. `spanContext` would supply this span's own trace id — a
    // distinction that cost real time: passing the resolved context as `spanContext` produced a
    // span carrying the caller's trace id with **no parent at all**, which looks connected in the
    // id column and is disconnected in the waterfall.
    //
    // Passed explicitly rather than relying on `Context.current`, so the parent is whatever
    // propagation resolved and never whatever happened to be ambient.
    context: resolved.context,
    kind: SpanKind.server,
    attributes: OTelAPI.attributesFromMap(<String, Object>{
      'http.request.method': normalizedMethod,
      'url.path': route,
      // The convention's name for a captured header rather than an invented one, so a reader of
      // the trace recognises it (D6).
      if (resolved.requestId != null)
        'http.request.header.x-request-id': resolved.requestId!,
    }),
  );

  return ServerSpanStart(span: span, propagation: resolved);
}

/// Records the outcome on [span] and ends it.
///
/// [statusCode] is null when the call produced no status — a transport that has no such concept, or
/// a failure before one was determined.
void completeServerSpan(
  APISpan span, {
  int? statusCode,
  Object? error,
  StackTrace? stackTrace,
}) {
  if (statusCode != null) {
    span.setIntAttribute('http.response.status_code', statusCode);
  }

  if (error != null) {
    span.recordException(error, stackTrace: stackTrace);
    span.setStatus(SpanStatusCode.Error, error.runtimeType.toString());
  } else if (statusCode != null && statusCode >= 500) {
    // 5xx is ours; 4xx is the caller's. Marking client mistakes as errors makes an error-rate
    // panel useless.
    span.setStatus(SpanStatusCode.Error, 'HTTP $statusCode');
  }

  span.end();
}
