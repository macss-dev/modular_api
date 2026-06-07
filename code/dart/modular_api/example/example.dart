/// example/example.dart
/// Minimal runnable example — mirrors example/example.dart from the Dart version.
///
/// Run:
///   dart run example/example.dart
///
/// Then test:
///   curl -X POST http://localhost:8080/api/v1/greetings/hello-world \
///        -H "Content-Type: application/json" \
///        -d '{"name":"World"}'
///   curl http://localhost:8080/api/v1/time/current-time?tz=utc-5
///
/// Docs:
///   http://localhost:8080/api/v1/docs
library;

import 'package:modular_api/modular_api.dart';

import 'health/always_pass_health_check.dart';
import 'modules/greetings/greetings_builder.dart';
import 'modules/time/time_builder.dart';

// ─── Server ───────────────────────────────────────────────────────────────────

Future<void> main(List<String> args) async {
  // First positional arg overrides the default port (e.g. `dart run example/example.dart 9090`).
  final port = args.isNotEmpty ? int.parse(args.first) : 8080;

  final api = ModularApi(
    basePath: '/api/v1',
    title: 'Modular API',
    version: '1.0.0',
    // OpenAPI servers — shown in Swagger UI "Try it out" dropdown.
    // When omitted, defaults to http://localhost:{port}.
    // servers: [
    //   {'url': 'https://miapi.example.com', 'description': 'Production'},
    //   {'url': 'http://192.168.5.82:8080', 'description': 'LAN'},
    // ],
    // Opt-in Prometheus metrics at GET /api/v1/metrics
    metricsEnabled: true,
    // Structured JSON logging (Loki/Grafana compatible)
    logLevel: LogLevel.debug,
  );

  // Register health checks (optional — /api/v1/health works without any checks)
  api.addHealthCheck(AlwaysPassHealthCheck());

  // Register custom metrics (only when metricsEnabled: true)
  // ignore: unused_local_variable
  final customOps = api.metrics?.createCounter(
    name: 'greetings_total',
    help: 'Total greetings served.',
  );

  api.module('greetings', buildGreetingsModule);
  api.module('time', buildTimeModule);

  await api.serve(port: port);
}
