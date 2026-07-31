import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:shelf/shelf.dart';

import 'propagation_policy.dart';

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
/// **Host-owned, not plugin-owned.** This is installed by the host immediately
/// inside `loggingMiddleware` and therefore outside every plugin middleware, which
/// is the whole point: a span created from inside a plugin slot would miss the
/// plugin middleware registered before it, leaving a hole in the waterfall exactly
/// where cold start and early middleware live. ADR-0005 decision 4 exists because
/// the first draft of this design got that wrong.
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

      final method = request.method.toUpperCase();

      final resolved = policy.resolve(request.headers);

      final span = tracer.startSpan(
        // Semantic convention for an HTTP server span: method then route.
        '$method $path',
        // `context`, never `spanContext`. The two are easy to confuse and the SDK
        // treats them very differently: `spanContext` supplies the new span's own
        // trace id, while the parent link is read from `context.spanContext`.
        // Passing the resolved context as `spanContext` produced a span with the
        // caller's trace id and no parent at all — a trace that looks plausible
        // and is silently disconnected. Caught by the parenting test.
        //
        // Passing it explicitly rather than relying on `Context.current` also
        // keeps this deterministic: the parent is whatever propagation resolved,
        // not whatever happened to be ambient.
        // `context` supplies the PARENT; `spanContext` would supply this span's own
        // trace id. Only the parent is wanted here: the tracer generates the trace id
        // for a root span, and the logger reads it back from the ambient span.
        //
        // An earlier design had the logger own the trace id and the span adopt it,
        // which needed `spanContext` in Dart and could not be expressed in TypeScript
        // without seeding a parent — where a seeded parent's trace flags made the
        // sampler drop the span. Reversing D12 removed the need entirely.
        //
        // Passing the resolved context explicitly rather than relying on
        // `Context.current` keeps parenting deterministic: the parent is whatever
        // propagation resolved, never whatever happened to be ambient.
        context: resolved.context,
        kind: SpanKind.server,
        attributes: OTelAPI.attributesFromMap(<String, Object>{
          'http.request.method': method,
          'url.path': path,
          // The convention's name for a captured header, rather than an invented
          // one, so a reader of the trace recognises it (D6).
          if (resolved.requestId != null)
            'http.request.header.x-request-id': resolved.requestId!,
        }),
      );

      final enriched = request.change(
        context: <String, Object>{
          ...request.context,
          tracingSpanContextKey: span,
          propagationResultContextKey: resolved,
        },
      );

      // Ambient for everything downstream: use cases, database commands and
      // outbound HTTP create child spans without anything being threaded through
      // call signatures.
      return tracer.withSpanAsync(span, () async {
        try {
          final response = await innerHandler(enriched);

          span.setIntAttribute('http.response.status_code', response.statusCode);

          // 5xx is ours; 4xx is the caller's. Marking client mistakes as errors
          // makes an error-rate panel useless.
          if (response.statusCode >= 500) {
            span.setStatus(SpanStatusCode.Error, 'HTTP ${response.statusCode}');
          }

          return response;
        } catch (error, stackTrace) {
          span.recordException(error, stackTrace: stackTrace);
          span.setStatus(SpanStatusCode.Error, error.runtimeType.toString());
          rethrow;
        } finally {
          span.end();
        }
      });
    };
  };
}
