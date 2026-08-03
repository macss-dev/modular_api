import 'dart:io';
// Prefixed deliberately: the OpenTelemetry API exports its own `LogLevel`, which
// collides with modular_api's. Any file importing both needs this.
import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart'
    as otel;
import 'package:shelf/shelf.dart';
import '../request_pipeline_audit.dart';
import 'logger.dart';
import 'uuid.dart';

/// Context key used to propagate the [RequestScopedLogger] through the
/// Shelf request pipeline.  Read it in handlers as:
/// ```dart
/// final logger = req.context['modular.logger'] as ModularLogger?;
/// ```
const loggerContextKey = 'modular.logger';

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

      // 1. Resolve the ids from the ambient span.
      //
      // The tracing middleware is outermost (D12 as reversed), so when tracing is
      // configured a recording span is already active here — and it stays active for
      // `request completed` too, which is emitted from inside its scope. That is what
      // lets both lines carry the same ids with nothing mutated afterwards.
      //
      // With no recording span, this is byte-for-byte the behaviour it always had: the
      // caller's X-Request-ID or a fresh dashed UUID. D5b's compatibility guarantee is
      // therefore structural rather than conditional — there is no tracing flag to
      // consult, only whether a span exists.
      final activeSpan = otel.Context.current.span;
      final tracingActive = activeSpan != null && activeSpan.spanContext.isValid;

      final String traceId;
      final String? spanId;
      final String? requestId;
      if (tracingActive) {
        traceId = activeSpan.spanContext.traceId.hexString;
        spanId = activeSpan.spanContext.spanId.hexString;
        // Preserved beside the trace id rather than promoted into it (D6).
        requestId = request.headers['X-Request-ID']?.isNotEmpty == true
            ? request.headers['X-Request-ID']
            : null;
      } else {
        traceId = request.headers['X-Request-ID']?.isNotEmpty == true
            ? request.headers['X-Request-ID']!
            : generateUuidV4();
        spanId = null;
        requestId = null;
      }

      // 2. Create per-request logger
      final logger = RequestScopedLogger(
        traceId: traceId,
        logLevel: logLevel,
        serviceName: serviceName,
        spanId: spanId,
        requestId: requestId,
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
