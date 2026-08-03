import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:shelf/shelf.dart';

import 'propagation_policy.dart';
import 'server_span.dart';

/// Context key under which the server span is exposed to downstream handlers.
///
/// Reading this is rarely necessary — the span is also made *ambient* for the
/// duration of the request, so `Context.current` finds it and child spans created
/// by `modular_api_postgres` or `modular_api_rest_client` attach automatically.
/// The key exists for code that needs the span object itself.
const String tracingSpanContextKey = 'modular.tracing.span';

/// Context key under which the resolved [PropagationResult] is exposed.
const String propagationResultContextKey = 'modular.tracing.propagation';

/// Creates the middleware that owns the server span.
///
/// **Host-owned, not plugin-owned.** This is installed by the host outside every plugin
/// middleware, which is the whole point: a span created from inside a plugin slot
/// would miss the plugin middleware registered before it, leaving a hole in the
/// waterfall exactly where cold start and early middleware live. ADR-0005
/// decision 4 exists because the first draft of this design got that wrong.
///
/// **Outermost, with `loggingMiddleware` inside it** (runbook D12 as reversed). The
/// logger then runs within this span's active scope, so it reads `trace_id` and
/// `span_id` from the ambient span on every line — including `request completed`,
/// which is emitted from inside the scope. The consequence is that `duration_ms` in
/// the log is slightly *smaller* than the span's duration, which is the right way
/// round: the span is the primary artifact and should cover the most.
///
/// The span is made ambient with `withSpanAsync`, so everything downstream —
/// use cases, database commands, outbound HTTP — can create child spans without
/// anything being threaded through call signatures.
///
/// **This is an adapter, and only an adapter.** Span construction lives in
/// `server_span.dart`, which knows nothing about HTTP or shelf, so the planned gRPC
/// transport arrives as a second adapter rather than a second copy (gate G4).
Middleware tracingMiddleware({
  required APITracer tracer,
  PropagationPolicy policy = const PropagationPolicy(),
  List<String> excludedRoutes = const <String>[],
}) {
  final excluded = Set<String>.from(excludedRoutes);

  return (Handler innerHandler) {
    return (Request request) async {
      final path = request.requestedUri.path;

      // Health, metrics and docs are noise in a trace store. The host derives this
      // list from operationalRoutePaths rather than hardcoding it.
      if (excluded.contains(path)) return innerHandler(request);

      final started = startServerSpan(
        tracer: tracer,
        method: request.method,
        route: path,
        headers: request.headers,
        policy: policy,
      );
      final span = started.span;

      final enriched = request.change(
        context: <String, Object>{
          ...request.context,
          tracingSpanContextKey: span,
          propagationResultContextKey: started.propagation,
        },
      );

      // Ambient for everything downstream: use cases, database commands and
      // outbound HTTP create child spans without anything being threaded through
      // call signatures.
      return tracer.withSpanAsync(span, () async {
        try {
          final response = await innerHandler(enriched);
          completeServerSpan(span, statusCode: response.statusCode);
          return response;
        } catch (error, stackTrace) {
          completeServerSpan(span, error: error, stackTrace: stackTrace);
          rethrow;
        }
      });
    };
  };
}
