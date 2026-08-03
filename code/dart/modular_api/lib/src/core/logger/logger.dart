import 'dart:convert';

import 'modular_logger.dart';
import 'log_sink.dart';

export 'modular_logger.dart' show LogLevel, ModularLogger;

/// Per-request logger that carries `traceId` and respects `logLevel` filtering.
///
/// Created by `LoggingMiddleware` for each incoming HTTP request and injected
/// into the UseCase via the `logger` property.
///
/// Accepts an optional [sink] for output — defaults to `stdout`.
/// In tests, pass a `StringBuffer` to capture output without side-effects.
/// Builds platform-specific correlation fields from the ids the framework resolved.
///
/// The framework emits open formats and nothing vendor-specific (roadmap invariant 7),
/// so a field like Google's `logging.googleapis.com/trace` — which needs a project id
/// the framework has no business knowing — is produced by the application:
///
/// ```dart
/// traceFieldFormatter: (traceId, spanId) => {
///   'logging.googleapis.com/trace': 'projects/my-project/traces/$traceId',
///   if (spanId != null) 'logging.googleapis.com/spanId': spanId,
/// }
/// ```
typedef TraceFieldFormatter = Map<String, Object> Function(
  String traceId,
  String? spanId,
);

class RequestScopedLogger implements ModularLogger {
  final String traceId;
  final LogLevel logLevel;
  final String serviceName;
  final StringSink _sink;

  /// The caller's `X-Request-ID`, when it sent one.
  ///
  /// Preserved beside [traceId] rather than promoted into it (runbook D6), so anyone
  /// correlating by the token they sent keeps working.
  final String? requestId;

  /// Builds platform correlation fields. `null` means none are emitted.
  final TraceFieldFormatter? traceFieldFormatter;

  /// The active server span's id, when tracing is configured.
  ///
  /// Known at construction because the tracing middleware is **outermost** (runbook
  /// D12 as reversed): the span already exists when `loggingMiddleware` creates this
  /// logger, so nothing needs mutating afterwards. An earlier design had logging
  /// outside tracing and had to attach this later, which is the scaffolding that
  /// reversal removed.
  final String? spanId;

  RequestScopedLogger({
    required this.traceId,
    required this.logLevel,
    required this.serviceName,
    this.spanId,
    this.requestId,
    this.traceFieldFormatter,
    StringSink? sink,
  }) : _sink = sink ?? defaultLogSink();

  // ─── Public API (8 RFC 5424 levels) ─────────────────────────────

  @override
  void emergency(String msg, {Map<String, dynamic>? fields}) =>
      _log(LogLevel.emergency, msg, fields: fields);

  @override
  void alert(String msg, {Map<String, dynamic>? fields}) =>
      _log(LogLevel.alert, msg, fields: fields);

  @override
  void critical(String msg, {Map<String, dynamic>? fields}) =>
      _log(LogLevel.critical, msg, fields: fields);

  @override
  void error(String msg, {Map<String, dynamic>? fields}) =>
      _log(LogLevel.error, msg, fields: fields);

  @override
  void warning(String msg, {Map<String, dynamic>? fields}) =>
      _log(LogLevel.warning, msg, fields: fields);

  @override
  void notice(String msg, {Map<String, dynamic>? fields}) =>
      _log(LogLevel.notice, msg, fields: fields);

  @override
  void info(String msg, {Map<String, dynamic>? fields}) =>
      _log(LogLevel.info, msg, fields: fields);

  @override
  void debug(String msg, {Map<String, dynamic>? fields}) =>
      _log(LogLevel.debug, msg, fields: fields);

  // ─── Framework-internal: request/response logging ───────────────

  /// Emits a "request received" log at `info` level.
  void logRequest({required String method, required String route}) {
    _log(
      LogLevel.info,
      'request received',
      extra: {'method': method, 'route': route},
    );
  }

  /// Emits a "request completed" log at the level determined by [statusCode].
  void logResponse({
    required String method,
    required String route,
    required int statusCode,
    required double durationMs,
    Map<String, dynamic>? extra,
  }) {
    _log(
      _levelForStatus(statusCode),
      'request completed',
      extra: {
        'method': method,
        'route': route,
        'status': statusCode,
        'duration_ms': durationMs,
        ...?extra,
      },
    );
  }

  /// Emits an "unhandled exception" log at `error` level.
  /// No stack trace, no exception message — by design (privacy/security).
  void logUnhandledException({
    required String route,
    required double durationMs,
  }) {
    _log(
      LogLevel.error,
      'unhandled exception',
      extra: {'route': route, 'status': 500},
    );
  }

  // ─── Internal helpers ───────────────────────────────────────────

  void _log(
    LogLevel level,
    String msg, {
    Map<String, dynamic>? fields,
    Map<String, dynamic>? extra,
  }) {
    // Filtering: only emit if the message level <= configured logLevel.
    if (level.value > logLevel.value) return;

    final entry = <String, dynamic>{
      'ts': DateTime.now().millisecondsSinceEpoch / 1000.0,
      'level': level.name,
      'severity': level.value,
      'msg': msg,
      'service': serviceName,
      'trace_id': traceId,
      if (spanId != null) 'span_id': spanId,
      if (requestId != null) 'request_id': requestId,
    };

    // Only when there is trace context to point at. A platform field naming a trace
    // that does not exist is worse than no field.
    final formatter = traceFieldFormatter;
    if (formatter != null && spanId != null) {
      entry.addAll(formatter(traceId, spanId));
    }

    if (extra != null) entry.addAll(extra);
    if (fields != null) entry['fields'] = fields;

    _sink.writeln(jsonEncode(entry));
  }

  /// Maps HTTP status code → RFC 5424 log level.
  static LogLevel _levelForStatus(int status) {
    if (status >= 500) return LogLevel.error;
    if (status >= 400) return LogLevel.warning;
    if (status >= 200 && status < 400) return LogLevel.info;
    // 1xx informational
    return LogLevel.notice;
  }
}
