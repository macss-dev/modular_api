/// Health check types following the IETF Health Check Response Format draft.
///
/// Spec: https://datatracker.ietf.org/doc/html/draft-inadarei-api-health-check
///
/// Status values: `pass`, `warn`, `fail`.
/// HTTP mapping: 200 for pass/warn, 503 for fail.
library;

/// Health status values — ordered by severity (pass < warn < fail).
///
/// The enum index doubles as severity: higher index = worse status.
/// This allows `HealthStatus.values` ordering for worst-status-wins aggregation.
enum HealthStatus {
  /// The component is healthy.
  pass,

  /// The component is healthy but has a warning condition.
  warn,

  /// The component is unhealthy.
  fail;

  /// Serialize to the IETF-mandated lowercase string.
  String toJson() => name; // 'pass', 'warn', 'fail'
}

/// Result returned by a single [HealthCheck].
class HealthCheckResult {
  /// Status of this individual check.
  final HealthStatus status;

  /// Time taken to execute the check, in milliseconds.
  /// Populated automatically by [HealthService]; checks themselves
  /// should leave this null — the service will fill it in.
  final int? responseTime;

  /// Optional human-readable output (e.g. error messages, warnings).
  final String? output;

  const HealthCheckResult({
    required this.status,
    this.responseTime,
    this.output,
  });

  /// Copy with a different [responseTime].
  HealthCheckResult withResponseTime(int ms) => HealthCheckResult(
        status: status,
        responseTime: ms,
        output: output,
      );

  /// Serialize to the IETF JSON structure.
  /// Only includes optional fields when they are non-null.
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'status': status.toJson()};
    if (responseTime != null) json['responseTime'] = responseTime;
    if (output != null) json['output'] = output;
    return json;
  }
}

/// Abstract base for custom health checks.
///
/// Implementors must provide [name] and [check].
/// Override [timeout] to change the default 5-second deadline.
///
/// Example:
/// ```dart
/// class DatabaseHealthCheck extends HealthCheck {
///   @override
///   final String name = 'database';
///
///   @override
///   Future<HealthCheckResult> check() async {
///     await db.ping();
///     return HealthCheckResult(status: HealthStatus.pass);
///   }
/// }
/// ```
abstract class HealthCheck {
  /// Display name used as the key in the `checks` map.
  String get name;

  /// Maximum time allowed before the check is considered failed.
  /// Override to customize per-check. Default: 5 seconds.
  Duration get timeout => const Duration(seconds: 5);

  /// Execute the health check and return a result.
  Future<HealthCheckResult> check();
}
