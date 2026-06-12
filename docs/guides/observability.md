# Observability Guide

Metrics (Prometheus) and structured logging (Loki/Grafana) in modular_api.
TypeScript examples; the Dart and Python SDKs expose the same surface with
idiomatic naming. Both endpoints resolve under the configured `basePath` (see
[operational-plugins.md](../concepts/operational-plugins.md)).

## Prometheus metrics

`GET {basePath}/metrics` exposes application metrics in
[Prometheus text exposition format](https://prometheus.io/docs/instrumenting/exposition_formats/)
(`text/plain; version=0.0.4; charset=utf-8`).

Disabled by default. Opt in via the constructor:

```ts
const api = new ModularApi({
  basePath: '/api/v1',
  version: '1.0.0',
  metricsEnabled: true, // enables GET /api/v1/metrics
});

await api.serve({ port: 8080 });
// Metrics -> http://localhost:8080/api/v1/metrics
```

### Built-in metrics

When enabled, every HTTP request is instrumented automatically:

| Metric | Type | Labels | Description |
|---|---|---|---|
| `http_requests_total` | Counter | `method`, `route`, `status_code` | Total number of HTTP requests |
| `http_request_duration_seconds` | Histogram | `method`, `route`, `status_code` | Request duration in seconds |
| `http_requests_in_flight` | Gauge | — | Requests currently being processed |
| `process_start_time_seconds` | Gauge | — | Process start time (unix epoch) |

Operational routes are excluded from instrumentation by default: the metrics path
itself, `{basePath}/health`, `{basePath}/docs`, and
`{basePath}/openapi.json|yaml`.

### Route normalization

The `route` label uses the registered path (e.g. `/api/v1/users/create`) when the
request matches a known endpoint. Since 0.5.0, registered **plugin routes** also
receive their real route label (ADR-0003). Requests to unregistered paths are
labeled `UNMATCHED` to prevent unbounded cardinality.

### Custom metrics

Access the `MetricsRegistrar` via `api.metrics` (returns `undefined` when metrics
are disabled):

```ts
// Counter
const logins = api.metrics?.createCounter({
  name: 'auth_logins_total',
  help: 'Total login attempts.',
});

// Gauge
const connections = api.metrics?.createGauge({
  name: 'db_connections_active',
  help: 'Active database connections.',
});

// Histogram (custom buckets optional)
const latency = api.metrics?.createHistogram({
  name: 'external_api_duration_seconds',
  help: 'External API call duration.',
  buckets: [0.01, 0.05, 0.1, 0.5, 1.0, 5.0],
});

// Inside use cases
logins?.inc();
connections?.set(pool.activeCount);
latency?.observe(elapsedMs / 1000);
```

Labeled metrics:

```ts
const errors = api.metrics?.createCounter({
  name: 'errors_total',
  help: 'Total errors by type.',
  labelNames: ['type'] as const,
});

errors?.inc({ type: 'validation' });
errors?.inc({ type: 'timeout' });
```

### Constructor options

| Option | Default | Description |
|---|---|---|
| `metricsEnabled` | `false` | Enable/disable the metrics endpoint |
| `metricsPath` | `'/metrics'` | Path (relative to `basePath`) where metrics are served |
| `excludedMetricsRoutes` | `['/metrics', '/health', '/docs']` | Routes excluded from instrumentation (joined under `basePath`; OpenAPI paths are always excluded as well) |

### Naming rules and implementation

- Metric names must match `[a-zA-Z_:][a-zA-Z0-9_:]*`; names starting with `__`
  are reserved by the framework.
- The TypeScript SDK is built on [prom-client](https://github.com/siimon/prom-client),
  the standard Prometheus client for Node.js; `Counter`, `Gauge`, and `Histogram`
  are re-exported from it.
- The metrics middleware runs in the `preRouting` plugin slot, ahead of user
  middlewares and routing, so it captures the full downstream request lifecycle
  (see [request-lifecycle.md](../concepts/request-lifecycle.md)).
- The endpoint always returns HTTP 200 regardless of metric values.

### Example output

```
# HELP http_requests_total Total number of HTTP requests.
# TYPE http_requests_total counter
http_requests_total{method="POST",route="/api/v1/greetings/hello",status_code="200"} 5

# HELP http_requests_in_flight Number of HTTP requests currently being processed.
# TYPE http_requests_in_flight gauge
http_requests_in_flight 0

# HELP http_request_duration_seconds HTTP request duration in seconds.
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{method="POST",route="/api/v1/greetings/hello",status_code="200",le="0.005"} 3
http_request_duration_seconds_count{method="POST",route="/api/v1/greetings/hello",status_code="200"} 5
http_request_duration_seconds_sum{method="POST",route="/api/v1/greetings/hello",status_code="200"} 0.023
```

## Structured JSON logging

Request-scoped structured logging compatible with Loki, Grafana, Elasticsearch,
and any JSON log aggregator. Enabled by default; every HTTP request gets a unique
`trace_id` for end-to-end correlation.

```ts
const api = new ModularApi({
  basePath: '/api/v1',
  title: 'My Service',          // becomes the "service" field in every log
  logLevel: LogLevel.info,      // default — emits emergency..info
});
```

Every request produces single-line JSON logs to stdout:

```json
{"ts":1718000000.123,"level":"info","severity":6,"msg":"request received","service":"My Service","trace_id":"a1b2c3d4-...","method":"POST","route":"/api/v1/greetings/hello"}
{"ts":1718000000.456,"level":"info","severity":6,"msg":"request completed","service":"My Service","trace_id":"a1b2c3d4-...","method":"POST","route":"/api/v1/greetings/hello","status":200,"duration_ms":3.21}
```

### Log levels (RFC 5424)

| Level | Value | When emitted |
|---|---|---|
| `emergency` | 0 | System unusable |
| `alert` | 1 | Immediate action required |
| `critical` | 2 | Critical condition |
| `error` | 3 | Operation errors, 5xx responses |
| `warning` | 4 | Abnormal conditions, 4xx responses |
| `notice` | 5 | Normal but significant |
| `info` | 6 | Normal flow, 2xx/3xx responses |
| `debug` | 7 | Detailed diagnostics |

Filtering rule: a message is emitted if `level.value <= logLevel.value`. Setting
`logLevel: LogLevel.warning` emits only emergency..warning.

Response logs map status codes automatically: 1xx `notice`, 2xx/3xx `info`,
4xx `warning`, 5xx `error`.

### Using the logger inside use cases

The framework injects a request-scoped logger into every use case via the
`logger` property:

```ts
async execute(): Promise<CreateUserOutput> {
  this.logger?.info(`Creating user: ${this.input.email}`);

  // ... business logic ...

  this.logger?.debug('User created successfully', {
    userId: newUser.id,
    email: this.input.email,
  });

  return new CreateUserOutput(newUser.id);
}
```

One method per RFC 5424 level: `emergency`, `alert`, `critical`, `error`,
`warning`, `notice`, `info`, `debug` — each accepting a message and optional
structured fields. The `?.` operator keeps the code working without a logger
(e.g. in unit tests).

### Trace ID / request correlation

- Auto-generated UUID v4 when no `X-Request-ID` header is present.
- Propagated when the client sends `X-Request-ID`.
- Echoed back as the `X-Request-ID` response header.

All logs within the same request share the same `trace_id`.

### JSON log format

| Field | Type | Present | Description |
|---|---|---|---|
| `ts` | number | always | Unix timestamp (seconds.milliseconds) |
| `level` | string | always | Level name (lowercase) |
| `severity` | number | always | RFC 5424 numeric value |
| `msg` | string | always | Log message |
| `service` | string | always | Service name (from `title`) |
| `trace_id` | string | always | Request correlation ID |
| `method` | string | request/response logs | HTTP method |
| `route` | string | request/response logs | Request path |
| `status` | number | response logs | HTTP status code |
| `duration_ms` | number | response logs | Request duration in ms |
| `fields` | object | when provided | Custom structured data |

Operational routes (`{basePath}/health`, `/docs`, `/openapi.json|yaml`, and the
metrics path) are excluded from request/response logging by default.

## Grafana / Loki

Logs are single-line JSON to stdout, so any container orchestrator can forward
them to Loki. Example query filtering by service and trace:

```logql
{job="my-service"} | json | service="My Service" | trace_id="a1b2c3d4-..."
```

Suggested Grafana dashboard panels:

| Panel | Source | Query sketch |
|---|---|---|
| Request rate | Prometheus | `sum(rate(http_requests_total[5m])) by (route)` |
| Error rate | Prometheus | `sum(rate(http_requests_total{status_code=~"5.."}[5m]))` |
| p95 latency | Prometheus | `histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, route))` |
| In-flight requests | Prometheus | `http_requests_in_flight` |
| Error log stream | Loki | `{job="my-service"} \| json \| severity <= 3` |
| Trace drill-down | Loki | filter by `trace_id` from any panel |

## Configuration reference

| Parameter | Type | Default | Description |
|---|---|---|---|
| `logLevel` | `LogLevel` | `LogLevel.info` | Minimum severity to emit |
| `title` | `string` | `'Modular API'` | Used as `service` field in logs |
| `metricsEnabled` | `boolean` | `false` | Enable the metrics endpoint |
| `metricsPath` | `string` | `'/metrics'` | Metrics path relative to `basePath` |
| `excludedMetricsRoutes` | `string[]` | `['/metrics', '/health', '/docs']` | Instrumentation exclusions |

## Parity notes

- **Dart**: same options on the `ModularApi` constructor (`metricsEnabled`,
  `logLevel: LogLevel.info`, etc.); metrics registrar via `api.metrics`.
- **Python**: snake_case options (`metrics_enabled`, `log_level`); same metric
  and log shapes.
