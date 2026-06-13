# Changelog

All notable changes to this project will be documented in this file.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/)
and the project adheres to [Semantic Versioning](https://semver.org/).

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
