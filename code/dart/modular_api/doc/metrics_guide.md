# Prometheus Metrics Endpoint

`GET /metrics` exposes application metrics in [Prometheus text exposition format](https://prometheus.io/docs/instrumenting/exposition_formats/) (`text/plain; version=0.0.4; charset=utf-8`).

Disabled by default. Opt in via the `metricsEnabled` constructor parameter.

---

## Quick start

```dart
final api = ModularApi(
  basePath: '/api',
  version: '1.0.0',
  metricsEnabled: true, // enables GET /metrics
);

await api.serve(port: 8080);
// Metrics → http://localhost:8080/metrics
```

---

## Built-in metrics

When enabled, the framework automatically instruments every HTTP request:

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `http_requests_total` | Counter | `method`, `route`, `status_code` | Total number of HTTP requests |
| `http_request_duration_seconds` | Histogram | `method`, `route`, `status_code` | Request duration in seconds |
| `http_requests_in_flight` | Gauge | — | Requests currently being processed |
| `process_start_time_seconds` | Gauge | — | Process start time (unix epoch) |

Routes excluded from instrumentation by default: `/metrics`, `/health`, `/docs`, `/docs/`.

---

## Custom metrics

Access the `MetricsRegistrar` via `api.metrics` (returns `null` when disabled):

```dart
final api = ModularApi(
  basePath: '/api',
  version: '1.0.0',
  metricsEnabled: true,
);

// Counter
final logins = api.metrics?.createCounter(
  name: 'auth_logins_total',
  help: 'Total login attempts.',
);

// Gauge
final connections = api.metrics?.createGauge(
  name: 'db_connections_active',
  help: 'Active database connections.',
);

// Histogram (custom buckets optional)
final latency = api.metrics?.createHistogram(
  name: 'external_api_duration_seconds',
  help: 'External API call duration.',
  buckets: [0.01, 0.05, 0.1, 0.5, 1.0, 5.0],
);
```

Use metrics inside your use cases:

```dart
logins?.inc();                                // increment counter
connections?.set(pool.activeCount.toDouble()); // set gauge value
latency?.observe(elapsed.inMilliseconds / 1000); // record histogram observation
```

### Labeled metrics

```dart
final errors = api.metrics?.createCounter(
  name: 'errors_total',
  help: 'Total errors by type.',
);

// Use .labels() to create labeled children.
errors?.labels({'type': 'validation'}).inc();
errors?.labels({'type': 'timeout'}).inc();
```

---

## Constructor options

| Parameter | Default | Description |
|-----------|---------|-------------|
| `metricsEnabled` | `false` | Enable/disable the metrics endpoint |
| `metricsPath` | `'/metrics'` | Path where metrics are served |
| `excludedMetricsRoutes` | `['/metrics', '/health', '/docs', '/docs/']` | Routes excluded from instrumentation |

```dart
final api = ModularApi(
  basePath: '/api',
  metricsEnabled: true,
  metricsPath: '/prometheus',
  excludedMetricsRoutes: ['/prometheus', '/health', '/docs', '/internal'],
);
```

---

## Metric naming rules

Names must match `[a-zA-Z_:][a-zA-Z0-9_:]*` (Prometheus convention).  
Names starting with `__` are reserved by the framework.

---

## Route normalization

The `route` label uses the registered path (e.g. `/api/users/create`) when the request matches a known endpoint. Requests to unregistered paths are labeled `UNMATCHED` to prevent unbounded cardinality.

---

## Example output

```
# HELP process_start_time_seconds Start time of the process since unix epoch in seconds.
# TYPE process_start_time_seconds gauge
process_start_time_seconds 1740000000

# HELP http_requests_total Total number of HTTP requests.
# TYPE http_requests_total counter
http_requests_total{method="POST",route="/api/greetings/hello",status_code="200"} 5

# HELP http_requests_in_flight Number of HTTP requests currently being processed.
# TYPE http_requests_in_flight gauge
http_requests_in_flight 0

# HELP http_request_duration_seconds HTTP request duration in seconds.
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{method="POST",route="/api/greetings/hello",status_code="200",le="0.005"} 3
http_request_duration_seconds_bucket{method="POST",route="/api/greetings/hello",status_code="200",le="0.01"} 5
http_request_duration_seconds_bucket{method="POST",route="/api/greetings/hello",status_code="200",le="+Inf"} 5
http_request_duration_seconds_count{method="POST",route="/api/greetings/hello",status_code="200"} 5
http_request_duration_seconds_sum{method="POST",route="/api/greetings/hello",status_code="200"} 0.023
```

---

## Implementation details

- **Zero runtime dependencies** — pure Dart implementation (no `prom-client` equivalent)
- Metric types: `Counter`, `Gauge`, `Histogram` with labeled variants
- Default histogram buckets: `[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]`
- Metrics middleware is injected as the **outermost** layer to capture full request lifecycle
- Always returns HTTP 200 regardless of metric values
