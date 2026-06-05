import 'dart:io';
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
}) {
  final excludedSet = Set<String>.from(excludedRoutes);

  return (Handler innerHandler) {
    return (Request request) async {
      final path = request.requestedUri.path;

      // Skip excluded routes (health, metrics, docs).
      if (excludedSet.contains(path)) {
        return innerHandler(request);
      }

      // 1. Resolve trace_id
      final traceId = request.headers['X-Request-ID']?.isNotEmpty == true
          ? request.headers['X-Request-ID']!
          : generateUuidV4();

      // 2. Create per-request logger
      final logger = RequestScopedLogger(
        traceId: traceId,
        logLevel: logLevel,
        serviceName: serviceName,
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
