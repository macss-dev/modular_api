// ─── Example Health Check ─────────────────────────────────────────────────────
// In a real project you'd check a database connection, external service, etc.

import 'package:modular_api/modular_api.dart';

class AlwaysPassHealthCheck extends HealthCheck {
  @override
  final String name = 'example';

  @override
  Future<HealthCheckResult> check() async {
    return HealthCheckResult(status: HealthStatus.pass);
  }
}
