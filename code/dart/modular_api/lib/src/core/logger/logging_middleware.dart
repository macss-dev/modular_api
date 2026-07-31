import 'dart:io';
// Prefixed deliberately: the OpenTelemetry API exports its own `LogLevel`, which
// collides with modular_api's. Any file importing both needs this.
import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart'
    as otel;
import 'package:shelf/shelf.dart';
import '../request_pipeline_audit.dart';
import '../tracing/propagation_policy.dart';
import 'logger.dart';
import 'uuid.dart';

/// Context key used to propagate the [RequestScopedLogger] through the
/// Shelf request pipeline.  Read it in handlers as:
/// ```dart
/// final logger = req.context['modular.logger'] as ModularLogger?;
/// ```
const loggerContextKey = 'modular.logger';

/// Context key carrying the [PropagationResult] `loggingMiddleware` resolved.
///
/// Present only when tracing is configured. The tracing middleware reads it rather
/// than resolving the headers a second time.
const resolvedPropagationContextKey = 'modular.propagation.resolved';

/// Context key carrying the trace id the logger is using.
const resolvedTraceIdContextKey = 'modular.propagation.traceId';

/// Creates a Shelf [Middleware] that:
///
/// 1. Reads or generates a `trace_id` (from `X-Request-ID` header).
/// 2. Creates a [RequestScopedLogger] scoped to the current request.
/// 3. Emits a `"request received"` log at `info` level.
/// 4. Passes the logger in `Request.context` for downstream handlers.
/// 5. Emits a `"request completed"` log (level based on status code).
/// 6. Returns the `X-Request-ID` header in the response.
///
/// Requests whose path matches [excludedRoutes] are passed through silently.
///
/// [sink] overrides the output target (defaults to `stdout`). Useful in tests.
Middleware loggingMiddleware({
  required LogLevel logLevel,
  required String serviceName,
  List<String> excludedRoutes = const [],
  StringSink? sink,
  PropagationPolicy? propagationPolicy,
  TraceFieldFormatter? traceFieldFormatter,
}) {
  final excludedSet = Set<String>.from(excludedRoutes);

  return (Handler innerHandler) {
    return (Request request) async {
      final path = request.requestedUri.path;

      // Skip excluded routes (health, metrics, docs).
      if (excludedSet.contains(path)) {
        return innerHandler(request);
      }

      // 1. Resolve trace_id.
      //
      // With a propagation policy — which the host supplies only when tracing is
      // configured — the trace id is the W3C one, resolved once here and reused by the
      // tracing middleware so the log and the span can never disagree. Without one,
      // this is byte-for-byte the behaviour it always had: the caller's X-Request-ID or
      // a fresh dashed UUID. That is D5b's compatibility guarantee, and it is why a
      // consumer who does not adopt tracing sees no log-format change at all.
      final propagation = propagationPolicy?.resolve(request.headers);
      final String traceId;
      if (propagation != null) {
        traceId = propagation.hasRemoteParent
            ? propagation.context.spanContext!.traceId.hexString
            : otel.OTelAPI.traceId().hexString;
      } else {
        traceId = request.headers['X-Request-ID']?.isNotEmpty == true
            ? request.headers['X-Request-ID']!
            : generateUuidV4();
      }

      // 2. Create per-request logger
      final logger = RequestScopedLogger(
        traceId: traceId,
        logLevel: logLevel,
        serviceName: serviceName,
        requestId: propagation?.requestId,
        traceFieldFormatter: traceFieldFormatter,
        sink: sink ?? stdout,
      );
      final auditState = RequestPipelineAuditState();

      final method = request.method.toUpperCase();
      final route = path;

      // 3. "request received"
      logger.logRequest(method: method, route: route);

      // 4. Propagate logger via context
      final enrichedRequest = request.change(
        context: {
          ...request.context,
          loggerContextKey: logger,
          requestPipelineAuditContextKey: auditState,
          // Resolved once, here. The tracing middleware reads this instead of
          // resolving again, so the trace id in the log and the trace id on the span
          // are the same value by construction rather than by coincidence.
          if (propagation != null) resolvedPropagationContextKey: propagation,
          if (propagation != null) resolvedTraceIdContextKey: traceId,
        },
      );

      // 5. Execute the inner handler chain
      final stopwatch = Stopwatch()..start();
      try {
        final response = await innerHandler(enrichedRequest);
        stopwatch.stop();

        final durationMs = stopwatch.elapsedMicroseconds / 1000.0;

        // 6. "request completed"
        logger.logResponse(
          method: method,
          route: route,
          statusCode: response.statusCode,
          durationMs: durationMs,
          extra: auditState.shortCircuit == null
              ? null
              : {
                  'short_circuit': true,
                  'short_circuit_plugin_id': auditState.shortCircuit!.pluginId,
                  'short_circuit_middleware_id': auditState.shortCircuit!.middlewareId,
                  'short_circuit_slot': auditState.shortCircuit!.slot,
                },
        );

        // 7. Attach X-Request-ID to response
        return response.change(headers: {'X-Request-ID': traceId});
      } catch (e) {
        stopwatch.stop();

        // "unhandled exception" — error level, no stack trace, no exception msg
        logger.logUnhandledException(
          route: route,
          durationMs: stopwatch.elapsedMicroseconds / 1000.0,
        );

        rethrow;
      }
    };
  };
}
