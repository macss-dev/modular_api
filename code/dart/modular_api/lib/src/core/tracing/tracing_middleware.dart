import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:shelf/shelf.dart';

import '../logger/logger.dart';
import '../logger/logging_middleware.dart';
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
/// Inside `loggingMiddleware` rather than outside it so the logger can read the
/// resolved ids and emit them (runbook D12). The consequence is that `duration_ms`
/// in the log is always marginally larger than the span's duration, because the
/// span does not measure the logger's own overhead.
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

      // Reuse what `loggingMiddleware` already resolved when it is present. Resolving
      // twice would produce two different generated trace ids for one request — the
      // log pointing at one trace and the span living in another — so this is a
      // correctness requirement, not an optimisation.
      final resolved =
          (request.context[resolvedPropagationContextKey] as PropagationResult?) ??
              policy.resolve(request.headers);

      // The logger owns the trace id, so a locally generated one must come from there
      // rather than from the tracer, or the two would disagree.
      final inheritedTraceId =
          request.context[resolvedTraceIdContextKey] as String?;

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
        // The two parameters do different jobs, and using the wrong one is the
        // single easiest mistake here:
        //
        // - `context` supplies the PARENT. The parent link is read from
        //   `context.spanContext`.
        // - `spanContext` supplies this span's own TRACE ID, and nothing else.
        //
        // A remote parent goes through `context`. A root span goes through
        // `spanContext`, so it adopts the trace id the logger already committed to
        // rather than letting the tracer mint a second one — which would leave the
        // log pointing at a trace the span does not belong to.
        //
        // Seeding a context instead does not work: a SpanContext with an invalid span
        // id is not valid, so the SDK discards it and generates a fresh trace id.
        // Found by the test asserting the log and the span agree.
        context: resolved.hasRemoteParent ? resolved.context : null,
        spanContext: resolved.hasRemoteParent
            ? null
            : _traceIdCarrier(inheritedTraceId),
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

      // Attach the span id to the logger the outer middleware created. It is the same
      // object that will emit `request completed` after this span has ended, so this is
      // what makes the line carrying `duration_ms` correlate at all.
      final logger = request.context[loggerContextKey];
      if (logger is RequestScopedLogger) {
        logger.spanId = span.spanContext.spanId.hexString;
      }

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

/// Carries [traceId] into `startSpan`, so a root span adopts the id the logger already
/// committed to instead of the tracer minting a second one.
///
/// Only the trace id is read from the returned value; the span id is filler.
SpanContext? _traceIdCarrier(String? traceId) {
  if (traceId == null) return null;
  try {
    return OTelAPI.spanContext(
      traceId: OTelAPI.traceIdFrom(traceId),
      spanId: OTelAPI.spanId(),
    );
  } catch (_) {
    // A trace id that is not valid hex — only reachable when no propagation policy is
    // in play, where tracing is off anyway. Fall back to a fresh trace.
    return null;
  }
}
