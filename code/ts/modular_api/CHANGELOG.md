# Changelog

All notable changes to this project will be documented in this file.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## [0.7.0] - 2026-08-01

- **`trace_id` changes shape when tracing is configured.** Without `tracing` it stays a dashed UUID
  v4, exactly as before; with `tracing` it becomes the 32-hex W3C trace id of the server span, which
  is what a trace backend can join on. The change is **gated on adopting tracing** so that consumers
  who do not ask for it are unaffected. Check any query, dashboard or alert that assumes the dashed
  form — see [the observability guide](../../../docs/guides/observability.md#the-trace_id-shape-change)
- add distributed tracing: `tracing: TracingOptions(tracerProvider: ...)` on the `ModularApi`
  constructor. Absent means no spans, no propagation and no cost — there is no `tracingEnabled`
  boolean, so "off" cannot be misconfigured
- the framework **instruments**, the application **supplies the OTel SDK**. Core now declares the
  OpenTelemetry **API** as a direct dependency and will never declare an SDK, exporter, gRPC or
  protobuf; a test enforces that boundary. The API is no-op without an SDK, so tracing costs nothing
  until you configure a provider (ADR-0005 amendment A1/A2)
- the server span is opened by the host **outside every plugin middleware slot**, and made ambient,
  so a use case or satellite package reaches it with nothing threaded through any signature
- add `span_id` and `request_id` to log lines. `request_id` carries the client's `X-Request-ID`
  verbatim and is **never** used as the trace id and never invented: a retried request reuses its
  request id on purpose, so one request id can span several traces
- add a propagation chain, first-valid-wins: W3C `traceparent`/`tracestate`, then
  `X-Cloud-Trace-Context` so a trace started by a Google load balancer is not orphaned.
  `X-Cloud-Trace-Context` is **read** by default and **written** only when asked — the framework
  emits open formats and nothing vendor-specific
- add `trustIncomingTraceContext` (default `true`); set it `false` at an internet-facing edge, where
  a caller controlling `traceparent` controls which trace their request joins
- add `traceFieldFormatter`, the hook through which a platform correlation field such as
  `logging.googleapis.com/trace` reaches log lines. No vendor field is emitted by default, because
  the value needs a project id the framework does not know
- add `onShutdown`, invoked when the server closes. The framework owns the *timing*, the application
  owns the resource — it never shuts down or flushes a provider it did not create. On a scale-to-zero
  platform this is the only window a batching processor has to flush
- operational routes (health, docs, openapi, metrics) produce **no span**; the exclusion list is
  derived from the same source as the routes rather than hardcoded
- **tracing is not a plugin and has no endpoint.** The span must sit outside every plugin middleware
  slot, while a plugin registers *into* one by definition (ADR-0005 amendment A7)
- `duration_ms` is now slightly smaller than the server span, because tracing is the outermost layer
  and logging sits inside it. Expected, not a regression
- **TypeScript only:** call `provider.register()` when configuring the SDK. Without a registered
  context manager `context.with` does not propagate and every child span silently becomes a root —
  you get spans, they just are not a trace

## [0.6.1] - 2026-07-02

### Added

- **Web-safe DTO contract entry-point** — new `@macss/modular-api/dto` subpath
  export exposing only the runtime-free contract surface (`Input`, `Output`,
  `Field`, `getFieldMetadata`, `UseCaseException`, `InputValidationError`).
  Import it from packages shared with browser/front-end code to define and
  validate DTOs without pulling in the Express server runtime. The `usecase`
  module already imports the logger as a type-only import, so this surface is
  Node-global-free at runtime.

### Changed

- `package.json` now declares an `exports` map (`.` for the full barrel, `./dto`
  for the contract). The full barrel remains server-only.

## [0.6.0] - 2026-06-13

### Changed

- version bump for coordinated ecosystem release (ADR-0002); no functional changes in this package

## [0.5.0] - 2026-06-12

### Added

- **Plugin OpenAPI contributions (ADR-0003)** — `PluginRoute` gains an optional `openapi` field
  (standard OpenAPI Operation object); the official OpenApiPlugin merges `custom`/`transport`
  plugin routes into the generated spec, so plugin-served endpoints (e.g. binaries) appear in
  `/openapi.json`, `/openapi.yaml`, and `/docs`.
- **`PluginHost.routes()`** — read view of registered plugin routes (pluginId, method, mounted
  path, visibility, openapi operation).

### Changed

- **Metrics route labels cover plugin routes** — registered plugin route paths join
  `registeredPaths`, so plugin routes report their real `route` label instead of `UNMATCHED`.

## [0.4.8] - 2026-06-06

### Changed

- **Clean-room driver isolation** — the base package no longer declares `mssql` or `pg` in its manifest, so `@macss/modular-api` installs cleanly without concrete database drivers.
- **Optional SQL Server introspection** — SQL Server metadata support now relies on lazy driver loading and explains how to install `mssql` only when that engine-specific feature is used.

## [0.4.7] - 2026-06-01

### Changed

- **Plugin middleware guardrails** — request-completed logs now annotate attributable short-circuit metadata (`short_circuit_*`) when a plugin middleware terminates the pipeline before the core handler.
- **Host-owned error normalization** — uncaught plugin-pipeline exceptions now return a structured JSON `500` response instead of falling through to framework-default error pages.

## [0.4.6] - 2026-04-24

### Fixed

- **Re-release** — v0.4.5 npm package was published with a stale `dist/` that did not include `Field.object()` or body-parser error handler changes. All v0.4.5 changelog features are now correctly included in the published build.

### Changed

- **`prepublishOnly` script** — `npm run build` now runs automatically before `npm publish`, preventing stale build artifacts from being published (see ADR-0002).

## [0.4.5] - 2026-03-28

### Added

- **`servers` option** in `ModularApiOptions` — configures the OpenAPI `servers` field so Swagger UI "Try it out" targets the correct host (LAN IP, domain, reverse proxy URL). Defaults to `localhost:{port}` when omitted.
- **`bodyParserErrorHandler`** — Express error middleware that catches body-parser `SyntaxError` and returns 400 with structured JSON.
- **`Field.object()`** — decorator for nested JSON object fields (`type: 'object'`). Enables webhook payloads with arbitrary nested objects to be declared, validated, and documented in OpenAPI (issue #8).
- **`object` case in `isJsonTypeValid`** — validates that a field declared as `object` receives a plain object; rejects strings, arrays, and null.

### Fixed

- **body-parser SyntaxError now carries `trace_id`** — moved `express.json()` after `loggingMiddleware` in the middleware chain so malformed-body errors are logged as structured JSON with `trace_id` (issue #7).
- **`useCaseHandler` catch blocks use scoped logger** — `UseCaseException` and unexpected errors are now logged through `res.locals['modularLogger']` instead of `console.error`, enabling Loki correlation.

## [0.4.4] - 2026-03-14

### Changed

- **Swagger UI replaced with `@macss/docs-ui`** — the ~200-line inline HTML/CSS/JS reduced to a ~15-line bootloader that loads `@macss/docs-ui@0.1` from jsdelivr CDN
- Dark mode now delegated to `docs-ui` package — single source of truth across all three SDKs

## [0.4.3] - 2026-03-13

### Changed (BREAKING)

- **`execute()` returns `Promise<O>`** — no longer `Promise<void>`; the handler reads the returned Output directly
- **Removed `output` field** from `UseCase` — no mutable state; `execute()` returns the result
- **Removed `toJson()`** from `UseCase` — the handler calls `output.toJson()` on the returned value
- **`inputClass` / `outputClass` now required** in `UseCaseOptions` — OpenAPI schema extraction uses them directly
- **Removed Strategy 2 fallback** in OpenAPI schema extraction — no `factory({}).output` path

## [0.4.2] - 2026-03-12

### Added

- **Auto-schema generation** — `Input` and `Output` DTOs derive OpenAPI 3.0.3 schemas automatically from `@Field` decorator metadata
- `@Field` decorators — Stage 3 decorators: `.string()`, `.integer()`, `.number()`, `.boolean()`, `.array()`, `.optional()`
- `Symbol.metadata` polyfill for Node.js < 22 compatibility
- `getFieldMetadata()` / `FieldMeta` / `FieldOptions` — public API for reading decorator metadata
- `Input` / `Output` base classes provide concrete `toSchema()`, `toJson()`, `fromJson()` from decorator metadata
- Cross-language schema conformance tests against shared JSON fixtures

### Changed

- TypeScript target changed from `ES2020` to `ES2022` for Stage 3 decorator support
- Manual `toSchema()` override is deprecated — use `@Field` decorators instead (removal in v0.5.0)
- `_extractSchemas` simplified — decorator metadata resolves schemas without manual methods

## [0.4.1] - 2026-03-12

### Removed

- **`prom-client`** — removed external dependency; all Prometheus metrics are now pure TypeScript
- Zero runtime dependencies besides `express`

### Added

- `Counter`, `Gauge`, `Histogram` — pure TypeScript metric types with Prometheus text exposition format
- `DEFAULT_BUCKETS`, `MetricSample` — public exports for custom metric usage
- `SwaggerDocs` — replaced `swagger-ui-express` with built-in Swagger UI served via CDN
- Built-in dark mode support for Swagger UI (system-aware via `prefers-color-scheme`)
- Cross-language parity with Dart and Python implementations

## [0.4.0] - 2026-03-03

### Removed

- **BREAKING:** `useCaseTestHandler` — removed from public API and deleted `src/core/usecase_test_handler.ts`
  - Testing now uses direct constructor injection: instantiate the UseCase with its Input, call `validate()`, `execute()`, and assert on `output` directly
  - Barrel exports removed from `src/index.ts` (`useCaseTestHandler`, `TestResponse`)

### Added

- **`GET /openapi.json`** — returns the full OpenAPI 3.0 specification as `application/json`
- **`GET /openapi.yaml`** — returns the full OpenAPI 3.0 specification as `application/x-yaml`
- `openApiJsonHandler()` / `openApiYamlHandler()` — Express handlers for raw spec access
- `jsonToYaml()` — zero-dependency JSON-to-YAML converter
- Spec is cached at startup alongside Swagger UI (no per-request rebuild)
- Barrel exports: `buildOpenApiSpec`, `jsonToYaml`, `openApiJsonHandler`, `openApiYamlHandler`
- 18 new tests: jsonToYaml unit (8), /openapi.json integration (4), /openapi.yaml integration (5), consistency (1)

### Changed

- Added comprehensive testing guide (`doc/testing_guide.md`) documenting the constructor-injection approach
- Updated `README.md` examples to reflect the new testing pattern

## [0.3.0] - 2026-02-26

### Added

- **Structured JSON Logger** — request-scoped logging compatible with Loki, Grafana, Elasticsearch, and any JSON log aggregator
- `LogLevel` enum — 8 RFC 5424 severity levels (emergency..debug) with configurable filtering
- `ModularLogger` interface — 8 logging methods (one per level) with optional structured `fields` and `traceId` property
- `RequestScopedLogger` — implementation with injectable `writeFn` for testability
- `loggingMiddleware()` — Express middleware that creates a per-request logger with unique `trace_id`
- `trace_id` auto-generated (UUID v4 via `crypto.randomUUID()`) or propagated from `X-Request-ID` header
- `X-Request-ID` response header set on every response for client-side correlation
- Logger injected as `UseCase.logger` property — zero breaking change to `execute()` signature
- Automatic status-to-level mapping: 2xx→info, 4xx→warning, 5xx→error
- Excluded routes: `/health`, `/metrics`, `/docs`, `/docs/` (no request/response logs)
- `logLevel` option on `ModularApiOptions` (default: `LogLevel.info`)
- `useCaseTestHandler` now accepts optional `{ logger }` options parameter
- Barrel exports: `LogLevel`, `RequestScopedLogger`, `ModularLogger`, `loggingMiddleware`, `LOGGER_LOCALS_KEY`, `LoggingMiddlewareOptions`
- 51 new tests: logger (26), middleware (19), integration (6)
- Documentation: `doc/logger_guide.md`

## [0.2.0] - 2026-02-24

### Added

- **IETF Health Check Response Format** — `GET /health` now returns `application/health+json` following [draft-inadarei-api-health-check](https://datatracker.ietf.org/doc/html/draft-inadarei-api-health-check)
- `HealthCheck` abstract class — implement to register custom health checks (database, cache, queue, etc.)
- `HealthCheckResult` — result DTO with `status`, `responseTime` (ms), and optional `output`
- `HealthStatus` type — `'pass' | 'warn' | 'fail'` with worst-status-wins aggregation
- `HealthService` — executes checks in parallel with per-check configurable timeout (default: 5s)
- `HealthResponse` — aggregated response with `version`, `releaseId`, `checks` map, and `httpStatusCode` (200 for pass/warn, 503 for fail)
- `healthHandler()` — Express handler for `GET /health`
- `ModularApi.addHealthCheck()` — register health checks via method chaining
- `ModularApiOptions` now accepts `version` and optional `releaseId`
- `releaseId` defaults to `version-debug`; override via `process.env.RELEASE_ID`
- **Prometheus Metrics Endpoint** — opt-in `GET /metrics` in [Prometheus text exposition format](https://prometheus.io/docs/instrumenting/exposition_formats/)
- `MetricsRegistrar` — public API for registering custom metrics via `api.metrics`
- `metricsEnabled`, `metricsPath`, `excludedMetricsRoutes` constructor options
- Built-in HTTP instrumentation: `http_requests_total`, `http_request_duration_seconds`, `http_requests_in_flight`, `process_start_time_seconds`
- `prom-client` dependency for Prometheus metric types
- Test infrastructure: vitest + supertest

### Changed

- **BREAKING:** `GET /health` response changed from plaintext `ok` to JSON `application/health+json`
- **BREAKING:** `ModularApiOptions` extended — `version` parameter added (defaults to `'0.0.0'`)

## [0.1.0] - 2026-02-21

### Added

- **Initial release** — TypeScript port of [modular_api](https://pub.dev/packages/modular_api) (Dart)
- `UseCase<I, O>`, `Input`, `Output` — abstract base classes for use-case centric architecture
- `UseCaseFactory<I, O>` — type alias for static `fromJson` factories
- `UseCaseException` — structured error handling with `statusCode`, `message`, `errorCode`, `details`
- `ModularApi` — main orchestrator: module registration, middleware pipeline, Express server
- `ModuleBuilder` — fluent builder to register use cases as HTTP endpoints
- `useCaseHandler` — wraps any `UseCaseFactory` into an Express `RequestHandler`
- `useCaseTestHandler` — unit test helper (no HTTP server required)
- `cors()` middleware — configurable CORS with zero dependencies
- Automatic OpenAPI 3.0 spec generation from registered use cases
- Swagger UI auto-mounted at `GET /docs`
- Health check at `GET /health`
- All endpoints default to `POST` (configurable per use case)
- Schema introspection via `Input.toSchema()` / `Output.toSchema()`
- Custom HTTP status codes via `Output.statusCode` getter
- Full TypeScript declarations (`.d.ts`) included

### Stack

- Express 4.x
- swagger-ui-express 5.x
- TypeScript 5.x, strict mode, ES2020 target
