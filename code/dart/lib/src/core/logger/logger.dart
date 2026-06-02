import 'dart:convert';
import 'dart:io';

/// RFC 5424 log levels in descending severity order.
///
/// Filtering rule: if configured `logLevel = X`, only messages with
/// `value <= X` are emitted. Higher values produce total silence.
enum LogLevel {
  emergency, // 0 — system unusable
  alert, // 1 — immediate action required
  critical, // 2 — critical condition
  error, // 3 — operation error, 5xx
  warning, // 4 — abnormal condition, 4xx
  notice, // 5 — normal but significant
  info, // 6 — normal flow, 2xx/3xx
  debug; // 7 — detailed diagnostics

  /// RFC 5424 numeric value (0–7).
  int get value => index;
}

/// Public logger interface exposed to UseCases.
///
/// Each method corresponds to an RFC 5424 severity level.
/// [fields] is an optional map of structured data attached to the log entry.
abstract class ModularLogger {
  void emergency(String msg, {Map<String, dynamic>? fields});
  void alert(String msg, {Map<String, dynamic>? fields});
  void critical(String msg, {Map<String, dynamic>? fields});
  void error(String msg, {Map<String, dynamic>? fields});
  void warning(String msg, {Map<String, dynamic>? fields});
  void notice(String msg, {Map<String, dynamic>? fields});
  void info(String msg, {Map<String, dynamic>? fields});
  void debug(String msg, {Map<String, dynamic>? fields});
}

/// Per-request logger that carries `traceId` and respects `logLevel` filtering.
///
/// Created by `LoggingMiddleware` for each incoming HTTP request and injected
/// into the UseCase via the `logger` property.
///
/// Accepts an optional [sink] for output — defaults to `stdout`.
/// In tests, pass a `StringBuffer` to capture output without side-effects.
class RequestScopedLogger implements ModularLogger {
  final String traceId;
  final LogLevel logLevel;
  final String serviceName;
  final StringSink _sink;

  RequestScopedLogger({
    required this.traceId,
    required this.logLevel,
    required this.serviceName,
    StringSink? sink,
  }) : _sink = sink ?? stdout;

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
    };

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
