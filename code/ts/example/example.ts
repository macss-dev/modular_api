/**
 * example/example.ts
 * Minimal runnable example — mirrors example/example.dart from the Dart version.
 *
 * Run:
 *   npx ts-node example/example.ts
 *
 * Then test:
 *   curl -X POST http://localhost:8080/api/v1/greetings/hello-world \
 *        -H "Content-Type: application/json" \
 *        -d '{"name":"World"}'
 *   curl http://localhost:8080/api/v1/time/current-time?tz=utc-5
 *
 * Docs:
 *   http://localhost:8080/api/v1/docs
 */

import { ModularApi, LogLevel } from '../src/index';
import { AlwaysPassHealthCheck } from './health/always_pass_health_check';
import { buildGreetingsModule } from './modules/greetings/greetings_builder';
import { buildTimeModule } from './modules/time/time_builder';

// ─── Server ───────────────────────────────────────────────────────────────────

// First CLI arg overrides the default port (e.g. `npx tsx example/example.ts 9090`).
const port = Number(process.argv[2]) || 8080;

const api = new ModularApi({
  basePath: '/api/v1',
  title: 'Modular API',
  version: '1.0.0',
  // OpenAPI servers — shown in Swagger UI "Try it out" dropdown.
  // When omitted, defaults to http://localhost:{port}.
  // servers: [
  //   { url: 'https://miapi.example.com', description: 'Production' },
  //   { url: 'http://192.168.5.82:8080', description: 'LAN' },
  // ],
  metricsEnabled: true,
  logLevel: LogLevel.debug,
});

// Register health checks (optional — /api/v1/health works without any checks)
api.addHealthCheck(new AlwaysPassHealthCheck());

// Register a custom metric (optional).
if (api.metrics) {
  api.metrics.createCounter({
    name: 'greetings_total',
    help: 'Total number of greetings sent.',
  });
}

api.module('greetings', buildGreetingsModule);
api.module('time', buildTimeModule);

api.serve({ port });
