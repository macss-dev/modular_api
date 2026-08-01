# Observability Guide

Metrics (Prometheus), structured logging (Loki/Grafana) and distributed tracing
(OpenTelemetry) in modular_api. TypeScript examples; the Dart and Python SDKs
expose the same surface with idiomatic naming. The metrics and health endpoints
resolve under the configured `basePath` (see
[operational-plugins.md](../concepts/operational-plugins.md)).

**Tracing has no endpoint.** Spans leave through an exporter the application
configures, not over HTTP, which is why it is not in the operational-plugins
table and is not a plugin at all — see [ADR-0005](../adr/0005-tracing-in-core-speaking-otlp.md)
amendment A7.

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

`trace_id` correlates every log line of one request. **Its shape depends on
whether tracing is configured**, which is the one thing to read before upgrading:

| `tracing` | `trace_id` | Source |
|---|---|---|
| not configured | `a1b2c3d4-e5f6-...` (dashed UUID v4) | generated per request, as before |
| configured | `4bf92f3577b34da6a3ce929d0e0e4736` (32 hex, no dashes) | the W3C trace id of the server span |

The second form is the one a trace backend can join on. The first is kept
verbatim for every existing consumer — see
[The `trace_id` shape change](#the-trace_id-shape-change) below, which is
required reading if anything parses your logs.

`request_id` is a **separate field** and carries the client's `X-Request-ID`
verbatim, or is absent when the client sent none. It is never used as the trace
id and is never invented:

- A retried request reuses its `X-Request-ID` on purpose, so one request id can
  span several traces. Collapsing them would merge unrelated latency.
- Most clients send no `X-Request-ID` at all, so a framework that derived the
  trace id from it would be generating one and calling it correlation.
- It is still echoed back as the `X-Request-ID` response header.

This split is the industry norm, not an invention here: Envoy propagates
`x-request-id` as an obligation separate from trace context, and
`macss-modular-api-rest-client` forwards it on outbound calls **whether or not
tracing is enabled** — so correlation survives a hop into a service that does
not trace at all.

### JSON log format

| Field | Type | Present | Description |
|---|---|---|---|
| `ts` | number | always | Unix timestamp (seconds.milliseconds) |
| `level` | string | always | Level name (lowercase) |
| `severity` | number | always | RFC 5424 numeric value |
| `msg` | string | always | Log message |
| `service` | string | always | Service name (from `title`) |
| `trace_id` | string | always | Request correlation ID. Dashed UUID without tracing, 32-hex W3C trace id with it |
| `span_id` | string | only with tracing | 16-hex id of the server span, so a log line points at one node of the waterfall |
| `request_id` | string | when the client sent `X-Request-ID` | The client's value, verbatim and never generated |
| `method` | string | request/response logs | HTTP method |
| `route` | string | request/response logs | Request path |
| `status` | number | response logs | HTTP status code |
| `duration_ms` | number | response logs | Request duration in ms |
| `fields` | object | when provided | Custom structured data |

Operational routes (`{basePath}/health`, `/docs`, `/openapi.json|yaml`, and the
metrics path) are excluded from request/response logging by default.

## Distributed tracing

modular_api **instruments** with OpenTelemetry; your application **supplies the
OTel SDK**. That split is the whole design, and everything else follows from it.

### The dependency boundary

| Layer | Who ships it | What it does |
|---|---|---|
| OTel **API** | the framework, as a direct dependency | creating spans, reading and writing trace headers |
| OTel **SDK** | **your application** | sampling, batching, and where spans actually go |

The API is a no-op without an SDK: spans are created, record nothing, and cost
nothing measurable. So a consumer who never configures tracing pays one
resolution entry in their lockfile and no runtime cost — which is why this is a
core dependency rather than an optional package.

The framework will never depend on an SDK, an exporter, gRPC or protobuf. A test
in every affected package asserts that, because it is the kind of rule that
erodes silently: **you** choose the exporter, the endpoint, the sampler and the
batching, and the framework never picks a default endpoint on your behalf.

Pinned ranges, and one thing to expect:

| SDK | API dependency |
|---|---|
| Dart | `dartastic_opentelemetry_api: ^0.9.1` |
| TypeScript | `@opentelemetry/api: ^1.9.0` |
| Python | `opentelemetry-api>=1.44,<2` |

The Dart package is **pre-1.0 and its author has signalled a rename**. A rename
is a coordinated version bump for us, not a redesign — the OpenTelemetry API it
implements is the specified, stable one, and that is what our code is written
against.

### Wiring it up

Three things: build a provider with an exporter, pass it to `ModularApi`, and
give the framework a way to flush on shutdown.

```ts
import { NodeTracerProvider } from '@opentelemetry/sdk-trace-node';
import { BatchSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { ModularApi, TracingOptions } from '@macss/modular-api';

const provider = new NodeTracerProvider({
  spanProcessors: [
    new BatchSpanProcessor(
      new OTLPTraceExporter({ url: 'http://localhost:4318/v1/traces' }),
    ),
  ],
});

// REQUIRED, and the one step that fails quietly if you skip it. `register()`
// installs the context manager; without it `context.with` does not propagate and
// every child span silently becomes a root — you get spans, they just are not a
// trace.
provider.register();

const api = new ModularApi({
  basePath: '/api',
  title: 'socia-api',
  tracing: new TracingOptions({
    tracerProvider: provider,
    onShutdown: async () => provider.shutdown(),
  }),
});
```

```dart
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as sdk;

await sdk.OTel.initialize(
  serviceName: 'socia-api',
  endpoint: 'http://localhost:4318/v1/traces',
  // `spanProcessor` is SINGULAR, and the default exporter speaks gRPC. Targeting
  // an OTLP/HTTP Collector means passing the HTTP exporter explicitly.
  spanProcessor: sdk.BatchSpanProcessor(
    sdk.OtlpHttpSpanExporter(
      sdk.OtlpHttpExporterConfig(endpoint: 'http://localhost:4318/v1/traces'),
    ),
  ),
);

final api = ModularApi(
  basePath: '/api',
  title: 'socia-api',
  tracing: TracingOptions(
    tracerProvider: sdk.OTel.tracerProvider(),
    onShutdown: () async => sdk.OTel.tracerProvider().shutdown(),
  ),
);
```

```python
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

from modular_api import ModularApi
from modular_api.core.tracing.tracing_options import TracingOptions

provider = TracerProvider()
provider.add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter(endpoint="http://localhost:4318/v1/traces"))
)

api = ModularApi(
    base_path="/api",
    title="socia-api",
    tracing=TracingOptions(
        tracer_provider=provider,
        on_shutdown=provider.shutdown,
    ),
)
```

### `TracingOptions`

| Option | Default | What it is for |
|---|---|---|
| `tracerProvider` | **required** | The provider from your SDK. Required in the type system, so there is no "tracing enabled but nothing configured" state |
| `onShutdown` | `undefined` | Invoked when the server closes. See [Flushing on shutdown](#flushing-on-shutdown) |
| `propagators` | W3C, then Cloud Trace for reads | The chain used to read and write trace context; see [Propagation](#propagation) |
| `trustIncomingTraceContext` | `true` | Set `false` at an internet-facing edge |
| `instrumentationName` | `'modular_api'` | The instrumentation scope on emitted spans |
| `traceFieldFormatter` | `undefined` | Adds a platform correlation field to log lines; see [Google Cloud](#google-cloud-logging-correlation) |

There is no `tracingEnabled` boolean. Absence of `tracing` is the off switch,
which means "off" cannot be misconfigured.

### Flushing on shutdown

The framework **never** shuts down or flushes a provider it did not create. It
offers the moment; you decide what it means:

```ts
tracing: new TracingOptions({
  tracerProvider: provider,
  onShutdown: async () => provider.shutdown(),
})
```

On Cloud Run or any scale-to-zero platform this is not optional. The window
between the last response and the container being killed is the only chance a
batching processor has to flush, and a dropped batch looks exactly like an
endpoint that was never instrumented. A callback that throws is swallowed:
losing telemetry is bad, failing to stop is worse.

### What is instrumented

| Span | Kind | Where it comes from |
|---|---|---|
| `POST /api/cuenta/detalle` | server | the host, outside every plugin middleware |
| `POST get-cuenta-detalle` | client | `macss-modular-api-rest-client`, per outbound call |
| `SELECT cuenta` | client | `macss-modular-api-postgres`, per command |
| `TRANSACTION socia` | client | `macss-modular-api-postgres`, per transaction |
| `CONNECT socia` | client | `macss-modular-api-postgres`, per session acquisition |

Operational routes — health, docs, openapi, metrics — produce **no span**. They
are noise in a trace store, and the exclusion list is derived from the same
source as the routes themselves rather than hardcoded.

The satellite packages need **no configuration**. They read the ambient span and
the global propagator, both of which the host publishes, so enabling tracing on
`ModularApi` is enough:

```ts
// Nothing tracing-related is passed here. The client span appears because a
// server span is active, and disappears when tracing is off.
const result = await client.execute(request, { decoder });
```

Database instrumentation is the one that is opted into explicitly, by wrapping:

```ts
import { traceDbClient } from '@macss/modular-api-postgres';

const traced = traceDbClient(client);              // SQL text NOT recorded
const verbose = traceDbClient(client, { includeQueryText: true });
```

**Not wrapping is how you turn database tracing off**, so it costs nothing when
unused. The SQL text is off by default because it can carry personal or financial
data in a literal, and a span is not somewhere that gets reviewed for that.
Parameter *values* are never recorded either way: the text is a template, the
parameters are the data.

Spans use the **stable** database conventions — `db.system.name`, `db.namespace`,
`db.operation.name`, `db.query.text`. The older `db.system`, `db.name`,
`db.operation` and `db.statement` are deprecated and are not emitted.

### Propagation

Incoming trace context is resolved by a chain, **first valid wins**:

1. W3C `traceparent` / `tracestate` — the standard, and what any conformant caller sends
2. `X-Cloud-Trace-Context` — read, so a trace started by a Google load balancer is not orphaned

`tracestate` is carried through verbatim. A propagator that throws on malformed
input does not break resolution: the chain moves on, and a bad header costs you a
parent, not a request.

**`X-Cloud-Trace-Context` is written only when you ask for it.** It is read by
default because it costs nothing and rescues a trace; it is not written by
default because the framework emits open formats and nothing vendor-specific.

> **The decimal span-id trap.** `X-Cloud-Trace-Context` is
> `TRACE_ID/SPAN_ID;o=1`, where `TRACE_ID` is 32 hex characters but `SPAN_ID` is
> a **decimal** integer — not hex, unlike every other trace header. Treating it
> as hex yields a valid-looking span id that points at nothing, and the trace
> appears connected while the waterfall is broken. Handled by
> [`opentelemetry_propagator_gcp`](https://pub.dev/packages/opentelemetry_propagator_gcp)
> in Dart and by the official propagators in TypeScript and Python.

At an internet-facing edge, set `trustIncomingTraceContext: false`. A caller who
controls `traceparent` controls which trace their request joins, and can graft
requests onto someone else's trace or force sampling. Inside a private network
the default is what you want.

### Sampling

Sampling is the SDK's, so it is yours. Two things worth knowing about how it
interacts with what the framework does:

- The framework does not set `TraceFlags` on an incoming context. If a caller
  sends `traceparent` with the sampled flag clear, a `ParentBased` sampler will
  drop the span — correctly. Overriding that would mean the framework
  second-guessing the application's sampler.
- Sampling is decided at the root, so a sampled trace keeps all its spans. Do
  not expect a head-based sampler to give you "some spans of every request".

For a latency investigation, sample at 100% for a bounded window rather than
raising a permanent rate.

### Collector topology

```
  your service ──OTLP/HTTP──> Collector (sidecar) ──> your backend
```

A sidecar rather than direct export, for two reasons: the export is a local hop,
so a slow or unavailable backend cannot add latency to your request path; and the
Collector is where you add batching, retry and redaction without redeploying the
service. The framework ships no default endpoint, so `localhost:4318` is a
convention, not a fallback.

### Cold start is not a span

A span begins when the framework receives the request. Container startup —
cold start, JIT warm-up, connection pool creation — happens **before** that, and
producing a span for it would mean inventing a start time we do not have.

That time is not lost: on Cloud Run it appears as a **gap** between the platform's
own request span and ours. If your p99 has a gap at the front and your spans do
not, you are looking at cold start, and no amount of application instrumentation
will show it from the inside.

### `duration_ms` is larger than the server span

Expected, and worth knowing before you file it as a bug. Tracing is the outermost
middleware and logging sits inside it, so the server span opens before the
response log is written and closes after. The gap is the logging middleware's own
work — small, and real.

### Google Cloud logging correlation

Cloud Logging joins a log line to a trace through
`logging.googleapis.com/trace`, whose value needs your **project id**. The
framework does not know it and will not guess, so the field comes from a
formatter you supply:

```ts
tracing: new TracingOptions({
  tracerProvider: provider,
  traceFieldFormatter: ({ traceId, spanId }) => ({
    'logging.googleapis.com/trace': `projects/socia-prod/traces/${traceId}`,
    'logging.googleapis.com/spanId': spanId,
  }),
})
```

No vendor-specific field is emitted by default. This hook is how a platform field
gets there without the framework knowing which platform you are on.

### The `trace_id` shape change

**Read this before upgrading if anything parses your logs.**

`trace_id` changes shape when — and only when — you configure `tracing`:

| `tracing` | `trace_id` |
|---|---|
| not configured | `a1b2c3d4-e5f6-7890-abcd-ef1234567890` (dashed UUID v4) |
| configured | `4bf92f3577b34da6a3ce929d0e0e4736` (32 hex, no dashes) |

Why it changes at all: a trace backend joins on the W3C trace id, and a dashed
UUID is not one. A log line carrying a different id from the span it describes is
correlation that looks like it works.

Why it is **gated on adopting tracing** rather than applied to everyone: the
dashed form is what every existing dashboard, LogQL query and alert already
matches. Changing it for consumers who did not ask for tracing would be a
breaking change with no benefit to them. Configuring `tracing` is an explicit,
deliberate act, and the shape change rides along with it.

What to check when you do adopt it:

- LogQL / SQL queries with a regex or length assumption on `trace_id`
- Anything joining log `trace_id` to an id produced elsewhere in your stack
- Alert rules that extract `trace_id` from a log line

Nothing else about the log format changes. `span_id` and `request_id` are
additive.

### Troubleshooting

| Symptom | Cause |
|---|---|
| Spans exist but every one is a root | **TypeScript:** `provider.register()` was not called, so there is no context manager |
| No spans at all | No SDK configured — the API is no-op by design. Check that `tracing` is actually passed |
| Spans stop appearing after a quiet period | No `onShutdown`, so the batch processor never flushed before the container was killed |
| Trace ids match but the waterfall is disconnected | A parent span context was used to set the *new* span's trace id instead of its parent |
| Nothing arrives at the Collector, no error | **Dart:** the default exporter speaks gRPC; pass `OtlpHttpSpanExporter` for an HTTP endpoint |
| Database spans missing | `traceDbClient` was not applied, or was applied to a different client instance than the one in use |
| `trace_id` looks wrong after upgrading | It is the W3C form now, and that is the shape change above |

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
| `tracing` | `TracingOptions?` | `undefined` | Absent means no spans and no propagation; see [Distributed tracing](#distributed-tracing) |

## Parity notes

- **Dart**: same options on the `ModularApi` constructor (`metricsEnabled`,
  `logLevel: LogLevel.info`, etc.); metrics registrar via `api.metrics`.
- **Python**: snake_case options (`metrics_enabled`, `log_level`); same metric
  and log shapes.
- **Tracing**: the span shape is identical in all three — same names, kinds,
  attribute keys and parent-child structure — and a cross-language check
  (`code/tests/integration_test/tracing_parity_test.ps1`) compares them against a
  shared fixture on every run. The differences are in the wiring, and are listed
  in [Wiring it up](#wiring-it-up): TypeScript needs `provider.register()`, Dart's
  `OTel.initialize` takes a singular `spanProcessor` and defaults to gRPC, and
  Python's `on_shutdown` may be sync or async because both are idiomatic there.
