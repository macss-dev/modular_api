/// Web-safe logging contract for modular_api.
///
/// Holds only the pure logging interface ([ModularLogger]) and severity levels
/// ([LogLevel]) — no `dart:io`. This lets the use-case contract (`Input`,
/// `Output`, `UseCase`) reference the logger type without dragging the server
/// runtime into web/desktop targets. The concrete `RequestScopedLogger`
/// implementation lives in `logger.dart`.
library;

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
