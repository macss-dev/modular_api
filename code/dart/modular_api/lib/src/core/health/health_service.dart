import 'dart:async';
import 'health_check.dart';

/// Aggregated health response following the IETF Health Check Response Format.
///
/// The [httpStatusCode] maps to:
///   - 200 for `pass` or `warn`
///   - 503 for `fail`
class HealthResponse {
  final HealthStatus status;
  final String version;
  final String releaseId;
  final Map<String, HealthCheckResult> checks;

  const HealthResponse({
    required this.status,
    required this.version,
    required this.releaseId,
    required this.checks,
  });

  /// HTTP status code to return.
  /// 200 for pass/warn, 503 for fail — as expected by load balancers and k8s.
  int get httpStatusCode => status == HealthStatus.fail ? 503 : 200;

  /// Serialize to the IETF-compliant JSON structure.
  Map<String, dynamic> toJson() => {
        'status': status.toJson(),
        'version': version,
        'releaseId': releaseId,
        'checks': checks.map((k, v) => MapEntry(k, v.toJson())),
      };
}

/// Service that manages and evaluates [HealthCheck]s.
///
/// Checks are executed in parallel with per-check timeout.
/// The overall status uses worst-status-wins aggregation:
///   fail > warn > pass.
///
/// ```dart
/// final service = HealthService(version: '1.0.0');
/// service.addHealthCheck(DatabaseHealthCheck());
/// service.addHealthCheck(CacheHealthCheck());
///
/// final response = await service.evaluate();
/// print(response.toJson());
/// ```
class HealthService {
  final String version;
  final String releaseId;
  final List<HealthCheck> _checks = [];

  /// Creates a health service.
  ///
  /// [version] — API version string (e.g. '1.0.0').
  /// [releaseId] — Defaults to `version-debug`. Override at compile time:
  ///   `dart compile exe --define=RELEASE_ID=1.2.3 bin/main.dart`
  HealthService({
    required this.version,
    String? releaseId,
  }) : releaseId = releaseId ?? _releaseIdFromEnvironment(version);

  /// Reads RELEASE_ID from compile-time environment.
  /// Falls back to `$version-debug` if not set.
  static String _releaseIdFromEnvironment(String version) {
    const envValue = String.fromEnvironment('RELEASE_ID');
    return envValue.isNotEmpty ? envValue : '$version-debug';
  }

  /// Register a [HealthCheck] to be evaluated on each call to [evaluate].
  void addHealthCheck(HealthCheck check) {
    _checks.add(check);
  }

  /// Execute all registered checks in parallel and return an aggregated
  /// [HealthResponse].
  ///
  /// Each check is executed with its own [HealthCheck.timeout].
  /// A check that exceeds its timeout or throws is marked as `fail`.
  /// Response times are measured in milliseconds.
  Future<HealthResponse> evaluate() async {
    if (_checks.isEmpty) {
      return HealthResponse(
        status: HealthStatus.pass,
        version: version,
        releaseId: releaseId,
        checks: {},
      );
    }

    // Run all checks in parallel
    final futures = _checks.map(_runCheck);
    final entries = await Future.wait(futures);

    final checks = Map.fromEntries(entries);

    // Worst-status-wins: fail > warn > pass
    final worstStatus = checks.values
        .map((r) => r.status)
        .reduce((a, b) => a.index >= b.index ? a : b);

    return HealthResponse(
      status: worstStatus,
      version: version,
      releaseId: releaseId,
      checks: checks,
    );
  }

  /// Run a single check with timeout and timing.
  Future<MapEntry<String, HealthCheckResult>> _runCheck(
    HealthCheck check,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final result = await check.check().timeout(
            check.timeout,
            onTimeout: () => HealthCheckResult(
              status: HealthStatus.fail,
              output: 'Health check "${check.name}" timeout after '
                  '${check.timeout.inMilliseconds}ms',
            ),
          );
      sw.stop();
      return MapEntry(
        check.name,
        result.withResponseTime(sw.elapsedMilliseconds),
      );
    } catch (e) {
      sw.stop();
      return MapEntry(
        check.name,
        HealthCheckResult(
          status: HealthStatus.fail,
          responseTime: sw.elapsedMilliseconds,
          output: e.toString(),
        ),
      );
    }
  }
}
