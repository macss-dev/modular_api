# Operational Plugins

Health, metrics, OpenAPI, and docs are provided by official plugins that use the
same public plugin contract as third-party plugins. All of them are mounted
**under the configured `basePath`** — there are no operational endpoints at the
server root.

| Endpoint | Method | Path (example with `basePath: '/api/v1'`) | Default |
|---|---|---|---|
| Health | GET | `/api/v1/health` | always on |
| Swagger UI / docs | GET | `/api/v1/docs` | always on |
| OpenAPI JSON | GET | `/api/v1/openapi.json` | always on |
| OpenAPI YAML | GET | `/api/v1/openapi.yaml` | always on |
| Metrics | GET | `/api/v1/metrics` | opt-in (`metricsEnabled: true`) |

## Migration note (pre-0.4.7 consumers)

Early 0.4.x versions (up to 0.4.4) served these endpoints at the server root
(`/health`, `/docs`, `/metrics`). Since 0.4.7 they resolve under the `basePath`.
After upgrading:

- Point container/orchestrator healthchecks to `{basePath}/health`
  (e.g. `/api/v1/health`), not `/health`.
- Update Prometheus scrape configs to `{basePath}/metrics`.
- Update any bookmark or reverse-proxy rule for `/docs` and `/openapi.json`.

See also [migration/0.4-to-0.5.md](../migration/0.4-to-0.5.md) and
[pitfalls.md](../pitfalls.md).

## Health check endpoint

`GET {basePath}/health` returns an
[IETF Health Check Response](https://datatracker.ietf.org/doc/html/draft-inadarei-api-health-check)
with `Content-Type: application/health+json`.

Without registered checks it responds 200 with:

```json
{ "status": "pass", "version": "1.0.0", "releaseId": "1.0.0-debug", "checks": {} }
```

`version` and `releaseId` come from the `ModularApi` constructor. The release id is
resolved in this order:

1. Explicit `releaseId` constructor option.
2. `RELEASE_ID` environment variable.
3. Fallback `${version}-debug`.

### Registering checks

Extend `HealthCheck` and call `addHealthCheck`:

```ts
import { ModularApi, HealthCheck, HealthCheckResult } from '@macss/modular-api';

class DatabaseHealthCheck extends HealthCheck {
  readonly name = 'database';

  async check(): Promise<HealthCheckResult> {
    await db.ping();
    return new HealthCheckResult('pass');
  }
}

const api = new ModularApi({ basePath: '/api/v1', version: '1.0.0' })
  .addHealthCheck(new DatabaseHealthCheck());
```

Each check provides:

| Member | Description |
|---|---|
| `name` | Key in the `checks` map (e.g. `"database"`) |
| `check()` | Async method returning a `HealthCheckResult` (`'pass'`, `'warn'`, `'fail'`, optional `output` message) |
| `timeout` | Optional getter, default 5000 ms |

`responseTime` is measured and injected by the framework.

### Aggregation

All checks run in parallel; the overall status is worst-status-wins:

| Check results | Overall status | HTTP code |
|---|---|---|
| All `pass` | `pass` | 200 |
| Any `warn`, none `fail` | `warn` | 200 |
| Any `fail` | `fail` | 503 |

A check that throws or exceeds its timeout is marked `fail`.

## Docs and OpenAPI endpoints

The docs UI (`{basePath}/docs`) renders the spec served at
`{basePath}/openapi.json` (also available as `.yaml`). The spec is generated from
the registered use cases plus, since 0.5.0, any plugin routes that declare an
`openapi` operation (visibility `custom` or `transport` — see
[plugin-host.md](plugin-host.md) and ADR-0003).

The `servers` constructor option controls the OpenAPI `servers` list (shown in the
"Try it out" dropdown); when omitted, `serve()` generates
`[{ url: 'http://localhost:{port}' }]`.

## Metrics endpoint

`GET {basePath}/metrics` (opt-in via `metricsEnabled: true`) serves Prometheus
text exposition format. Operational routes (health, docs, openapi.json/yaml, and
the metrics path itself) are excluded from instrumentation and from request
logging by default. Details, built-in metrics, and custom metric registration are
in the [observability guide](../guides/observability.md).

## Related

- [Observability](../guides/observability.md)
- [Request lifecycle](request-lifecycle.md)
- [Deployment](../guides/deployment.md) — basePath conventions and healthchecks
