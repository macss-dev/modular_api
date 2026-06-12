# Changelog
All notable changes to this project will be documented in this file.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/)
and the project adheres to [Semantic Versioning](https://semver.org/).

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

- **Clean-room driver isolation** — the base package no longer declares concrete SQL Server or Postgres drivers, so REST-only and GraphQL-base consumers can install/import `modular_api` without external database drivers.
- **Public physical model kept in core** — `PhysicalCatalog`, `PhysicalObject`, `PhysicalField`, `PhysicalRelationSeed`, and `PhysicalObjectKind` remain exported from the base package as GraphQL-base contracts.

### Removed

- **SQL Server metadata reader ownership from core** — the concrete SQL Server metadata reader and connection settings moved out of `modular_api` and into `modular_api_sqlserver`, keeping driver ownership at the engine-package boundary.

## [0.4.7] - 2026-06-01

### Changed

- **Plugin middleware guardrails** — request-completed logs now annotate attributable short-circuit metadata (`short_circuit_*`) when a plugin middleware terminates the pipeline before the core handler.
- **Host-owned error normalization** — uncaught plugin-pipeline exceptions now return a structured JSON `500` response instead of falling through to framework-default error handling.

## [0.4.6] - 2026-04-24

### Changed

- **Version bump for cross-SDK parity** — aligns with TypeScript 0.4.6 re-release (see ADR-0002). No functional changes.

## [0.4.5] - 2026-03-28

### Added

- **`servers` parameter** in `ModularApi` constructor — configures the OpenAPI `servers` field so Swagger UI "Try it out" targets the correct host (LAN IP, domain, reverse proxy URL). Defaults to `localhost:{port}` when omitted.
- **`corsMiddleware()`** — configurable CORS middleware replacing `exampleCorsMiddleware()`. Accepts `origin` (String or List), `methods`, and `allowedHeaders`. Aligned with TypeScript `cors()` and Python `cors_middleware()`.
- **`SchemaField.object()`** — factory constructor for nested JSON object fields (`type: 'object'`). Enables webhook payloads with arbitrary nested objects to be declared, validated, and documented in OpenAPI (issue #8).
- **`object` case in `_isJsonTypeValid`** — validates that a field declared as `object` receives a `Map` value; rejects strings, arrays, and other types.
- **`Map` case in `_inferOpenApiType`** — infers `'object'` for `Map` values in example-based schema generation.

### Fixed

- **`useCaseHttpHandler` catch blocks use scoped logger** — `UseCaseException` and unexpected errors are now logged through `req.context['modular.logger']` instead of `stderr.writeln`, enabling Loki correlation with `trace_id` (issue #7).

### Removed

- **`exampleCorsMiddleware()`** — replaced by the configurable `corsMiddleware()`

## [0.4.4] - 2026-03-14

### Changed

- **Swagger UI replaced with `@macss/docs-ui`** — the ~200-line inline HTML/CSS/JS reduced to a ~15-line bootloader that loads `@macss/docs-ui@0.1` from jsdelivr CDN
- Dark mode now delegated to `docs-ui` package — single source of truth across all three SDKs

## [0.4.3] - 2026-03-13

### Changed (BREAKING)

- **`execute()` returns `Future<O>`** — no longer `Future<void>`; the handler reads the returned Output directly
- **Removed `output` field** from `UseCase` — no mutable state; `execute()` returns the result
- **Removed `toJson()`** from `UseCase` — the handler calls `output.toJson()` on the returned value
- **`inputExample` / `outputExample` now required** in `ModuleBuilder.usecase()` — OpenAPI schema extraction uses them directly
- **Removed Strategy 2 fallback** in OpenAPI schema extraction — no `factory({}).output` path

### Removed

- **`@Field` annotation** — was decorative only (no runtime effect in Dart); `schemaFields` getter is the sole schema source

## [0.4.2] - 2026-03-12

### Added

- **Auto-schema generation** — `Input` and `Output` DTOs derive OpenAPI 3.0.3 schemas automatically from `schemaFields` getter + `SchemaField` metadata
- `@Field` annotation — decorative per-field documentation (`@Field(description: 'x')`)
- `SchemaField` class — metadata with factories: `.string()`, `.integer()`, `.number()`, `.boolean()`, `.array()`
- `buildSchema()` utility — converts `List<SchemaField>` to OpenAPI 3.0.3-compatible `Map<String, dynamic>`
- `Input` / `Output` base classes gain generative constructors and default `toSchema()` from `schemaFields`
- Cross-language schema conformance tests against shared JSON fixtures

### Changed

- DTOs now use `extends Input` / `extends Output` instead of `implements` (for inherited `toSchema()` default)
- Manual `toSchema()` override is deprecated — use `schemaFields` getter instead (removal in v0.5.0)

## [0.4.1] - 2026-03-12

### Changed

- Replaced `shelf_swagger_ui` with built-in Swagger UI served via CDN — zero external UI dependencies
- Built-in dark mode support for Swagger UI (system-aware via `prefers-color-scheme`)

### Added

- `SwaggerDocs` — internal handler serving the Swagger UI HTML page at `/docs`
- Cross-language parity with TypeScript and Python implementations

## [0.4.0] - 2026-03-03

### Removed

- **BREAKING:** `useCaseTestHandler` — removed from public API and deleted `lib/src/core/usecase/usecase_test_handler.dart`
  - Testing now uses direct constructor injection: instantiate the UseCase with its Input, call `validate()`, `execute()`, and assert on `output` directly
  - Barrel export removed from `lib/modular_api.dart`

### Added

- **`GET /openapi.json`** — returns the full OpenAPI 3.0 specification as `application/json`
- **`GET /openapi.yaml`** — returns the full OpenAPI 3.0 specification as `application/x-yaml`
- `OpenApi.openapiJson` / `OpenApi.openapiYaml` — Shelf handlers for raw spec access
- `OpenApi.jsonToYaml()` — zero-dependency JSON-to-YAML converter
- Spec is cached at startup alongside Swagger UI (no per-request rebuild)
- 18 new tests: jsonToYaml unit (8), /openapi.json integration (4), /openapi.yaml integration (5), consistency (1)

### Changed

- Updated testing guide (`doc/testing_guide.md`) to document the constructor-injection approach
- Updated `doc/usecase_implementation.md` and `doc/logger_guide.md` to remove `useCaseTestHandler` references
- Updated `AGENTS.md` and `README.md` examples to reflect the new testing pattern

## [0.3.0] - 2026-02-26
### Added
- **Structured JSON Logger** — request-scoped logging compatible with Loki, Grafana, Elasticsearch, and any JSON log aggregator
- `LogLevel` enum — 8 RFC 5424 severity levels (emergency..debug) with configurable filtering
- `ModularLogger` interface — 8 logging methods (one per level) with optional structured `fields`
- `RequestScopedLogger` — implementation with injectable `StringSink` for testability
- `loggingMiddleware()` — Shelf middleware that creates a per-request logger with unique `trace_id`
- `trace_id` auto-generated (UUID v4, zero dependencies) or propagated from `X-Request-ID` header
- `X-Request-ID` response header set on every response for client-side correlation
- Logger injected as `UseCase.logger` property — zero breaking change to `execute()` signature
- Automatic status-to-level mapping: 2xx→info, 4xx→warning, 5xx→error
- Excluded routes: `/health`, `/metrics`, `/docs`, `/docs/` (no request/response logs)
- `logLevel` parameter on `ModularApi` constructor (default: `LogLevel.info`)
- `useCaseTestHandler` now accepts optional `logger` parameter for test observability
- `generateUuidV4()` — manual UUID v4 using `dart:math Random.secure()` (no external deps)
- Barrel exports: `LogLevel`, `ModularLogger` from `package:modular_api/modular_api.dart`
- 68 new tests: logger (27), uuid (6), middleware (23), integration (12)
- Documentation: `doc/logger_guide.md`

## [0.2.0] - 2026-02-24
### Added
- **IETF Health Check Response Format** — `GET /health` now returns `application/health+json` following [draft-inadarei-api-health-check](https://datatracker.ietf.org/doc/html/draft-inadarei-api-health-check)
- `HealthCheck` abstract class — implement to register custom health checks (database, cache, queue, etc.)
- `HealthCheckResult` — result DTO with `status`, `responseTime` (ms), and optional `output`
- `HealthStatus` enum — `pass`, `warn`, `fail` with worst-status-wins aggregation
- `HealthService` — executes checks in parallel with per-check configurable timeout (default: 5s)
- `HealthResponse` — aggregated response with `version`, `releaseId`, `checks` map, and `httpStatusCode` (200 for pass/warn, 503 for fail)
- `healthHandler()` — Shelf handler for `GET /health`
- `ModularApi.addHealthCheck()` — register health checks via method chaining
- `ModularApi` constructor now accepts `version` and optional `releaseId` parameters
- `releaseId` defaults to `version-debug`; override at compile time with `--define=RELEASE_ID=x.y.z`
- **Prometheus Metrics Endpoint** — opt-in `GET /metrics` in [Prometheus text exposition format](https://prometheus.io/docs/instrumenting/exposition_formats/)
- `Counter`, `Gauge`, `Histogram` — pure Dart metric types (zero runtime dependencies)
- `MetricsRegistrar` — public API for registering custom metrics via `api.metrics`
- `metricsEnabled`, `metricsPath`, `excludedMetricsRoutes` constructor parameters
- Built-in HTTP instrumentation: `http_requests_total`, `http_request_duration_seconds`, `http_requests_in_flight`, `process_start_time_seconds`

### Changed
- **BREAKING:** `GET /health` response changed from plaintext `ok` to JSON `application/health+json`
- **BREAKING:** `ModularApi` constructor signature changed — added `version` parameter (defaults to `'0.0.0'`)

## [0.1.0] - 2026-02-21
### Changed
- **BREAKING:** Stripped to core-only — aligned Dart and TypeScript SDKs at feature parity
- Version bump from 0.0.10 to 0.1.0 (semver: new public API surface)
- `ModularApi` constructor no longer accepts `oauthService` parameter
- `ModuleBuilder.usecase()` no longer accepts `requiredScopes` parameter
- Reduced dependencies from 14 to 3 (`shelf`, `shelf_router`, `shelf_swagger_ui`)
- Simplified `doc/INDEX.md` to core-only development flow
- Example no longer uses `Env` — hardcoded port for simplicity

### Removed
- `lib/src/auth/` — `JwtHelper`, `OAuthService`, `OAuthClient`, `PasswordHasher`, `TokenHasher`, all OAuth2 types
- `lib/src/core/oauth_handler.dart` — `createOAuthTokenHandler`
- `lib/src/middlewares/apikey.dart` — `exampleApiKeyMiddleware`
- `lib/src/middlewares/bearer.dart` — `bearer()`, `requireAuth()`
- `lib/src/utils/env.dart` — `Env` utility
- `lib/src/utils/get_local_ip.dart` — `getLocalIp`
- Dependencies: `http`, `ffi`, `dotenv`, `path`, `cryptography`, `bcrypt`, `dart_jsonwebtoken`, `crypto`, `ffigen`
- Documentation: `auth_implementation_guide.md`, `authentication_guide.md`, `http_client_guide.md`

### Kept (Core)
- `UseCase<I, O>`, `Input`, `Output` — abstract base classes
- `UseCaseException` — structured error handling
- `ModularApi`, `ModuleBuilder` — routing and module registration
- `useCaseHttpHandler` — Shelf HTTP adapter
- `useCaseTestHandler` — unit test helper
- `exampleCorsMiddleware` — CORS middleware
- `OpenApi` — automatic Swagger/OpenAPI docs at `/docs`
- `GET /health` — health check endpoint

## [0.0.10] - 2025-12-23
### Added
- **`UseCaseException`** — Dedicated exception for use case execution errors:
  - `statusCode` — HTTP status code to return (400, 404, 422, 500, etc.)
  - `message` — Human-readable error message
  - `errorCode` — Optional error code for client-side handling
  - `details` — Optional additional details (validation errors, context)
  - Automatically caught by `useCaseHttpHandler` and converted to appropriate HTTP responses
  - Allows fine-grained control over error responses instead of generic 500 errors

### Changed
- Updated `useCaseHttpHandler` to catch `UseCaseException` and return the specified status code
- Enhanced error handling with structured error responses

## [0.0.9] - 2025-12-15
### Added
- **OAuth2 Client Credentials Support** — full OAuth2 implementation:
  - `OAuthService` — manages client authentication and JWT token generation
  - `OAuthClient` — represents registered clients with credentials and scopes
  - `TokenRequest`, `TokenResponse`, `TokenErrorResponse` — OAuth2 data structures
  - `AccessToken` — decoded JWT with scope validation methods
  - `createOAuthTokenHandler` — POST /oauth/token endpoint handler
  - `bearer()` middleware — validates Bearer tokens and enforces scopes
  - `requireAuth()` middleware — marks routes as requiring authentication
  - HS256 (HMAC-SHA256) JWT signing algorithm
  - Scope-based authorization for protected endpoints
  - Follows RFC 6749 OAuth2 specification

### Changed
- Exported auth utilities: `JwtHelper`, `hashPassword`, `verifyPassword`, `hashToken`
- Updated exports to include OAuth2 types and services

### Removed
- **Removed `template/` folder** — Simplified project structure by removing the full example template
  - Template project has been removed to reduce repository complexity
  - Only the minimal `example/` folder remains for quick reference
  - Previous template code included extensive examples, tests, and infrastructure that were redundant

### Documentation
- Added comprehensive OAuth2 guides and examples
- Updated AGENTS.md with OAuth2 usage patterns
- Updated all documentation to remove references to `template/` folder
- Simplified examples to focus on the minimal `example/` implementation
- Cleaned up README.md, AGENTS.md, and guides to reflect simplified structure

## [0.0.8] - 2025-12-04
### Added
- **Output.statusCode** — customizable HTTP status code for UseCase responses:
  - `Output` abstract class now includes `int get statusCode => 200;` getter
  - Override in your Output DTO to return custom HTTP status codes (e.g., 201 for created, 400 for bad request)
  - `useCaseHttpHandler` uses `output.statusCode` instead of hardcoded 200
  - Enables proper RESTful responses without modifying the HTTP handler

### Changed
- **Output DTOs** now use `extends Output` instead of `implements Output` to inherit the default `statusCode` getter
- Example and template Output classes updated to extend Output

### Migration Guide
If you have existing Output DTOs using `implements Output`, change them to `extends Output`:
```dart
// Before
class MyOutput implements Output { ... }

// After
class MyOutput extends Output { ... }
```
Alternatively, add the statusCode getter manually: `@override int get statusCode => 200;`

## [0.0.7] - 2025-11-04
### Added
- **httpClient** — intelligent HTTP client with automatic authentication:
  - Automatic token attachment for authenticated requests (`auth: true`)
  - Auto-capture of access and refresh tokens from login responses
  - Transparent retry with refresh token on 401 responses
  - Throws `AuthReLoginException` when refresh fails (signals re-login required)
  - Per-user token management via `user` parameter
- **Token** (in-memory session) — static class for managing access tokens:
  - `Token.accessToken` — current access token
  - `Token.accessExp` — access token expiration timestamp
  - `Token.isAuthenticated` — check if user has valid token
  - `Token.isExpired` — check if current token is expired
  - `Token.clear()` — clear session
- **TokenVault** (persistent storage) — configurable adapter for refresh tokens:
  - `TokenVault.saveRefresh(userId, token)` — persist refresh token
  - `TokenVault.readRefresh(userId)` — retrieve refresh token
  - `TokenVault.deleteRefresh(userId)` — delete specific refresh token
  - `TokenVault.deleteAll()` — clear all tokens
  - `TokenVault.configure(adapter)` — set storage adapter
  - Includes `MemoryStorageAdapter` (default) and `FileStorageAdapter` with optional encryption
- **JwtHelper** — JWT generation and validation utilities:
  - `generateAccessToken({userId, username})` — create access tokens (15 min)
  - `generateRefreshToken({userId, tokenId})` — create refresh tokens (7 days)
  - `verifyToken(token)` — validate and decode JWT
  - `calculateRefreshTokenExpiration()` — get refresh token expiry date
  - Reads secret from `JWT_SECRET` environment variable
- **PasswordHasher** — bcrypt password hashing:
  - `hash(password, {cost = 12})` — generate bcrypt hash
  - `verify(password, hash)` — verify password against hash
  - `needsRehash(hash, {cost})` — check if hash needs update
- **TokenHasher** — SHA-256 token hashing for secure storage:
  - `hash(token)` — generate SHA-256 hash (64 hex chars)
  - `verify(token, expectedHash)` — verify token against hash
- **AuthReLoginException** — specialized exception for auth flow control
- Comprehensive authentication documentation:
  - **docs/auth_implementation_guide.md** — Complete JWT authentication implementation guide with refresh tokens, including database setup, repository patterns, use cases, and client integration (Flutter & Dart)
  - **docs/http_client_guide.md** — Focused guide for using httpClient in Flutter and pure Dart applications with configuration examples and best practices
- Complete E2E authentication test suite:
  - `template/test/e2e/auth_flow_test.dart` — 25+ comprehensive tests covering login, refresh, logout, protected endpoints, concurrent requests, auto-refresh behavior, and re-login exception handling

### Changed
- All documentation translated to English for consistency

## [0.0.6] - 2025-10-30
### Added
- Exported `useCaseTestHandler` in main library export (`lib/modular_api.dart`) for convenient unit testing of UseCases without starting an HTTP server.
- Comprehensive documentation guides:
  - **AGENTS.md** — Framework overview and implementation guide optimized for AI assistants
  - **docs/USECASE_DTO_GUIDE.md** — Complete guide for creating Input/Output DTOs with type mapping reference and advanced examples
  - **docs/usecase_implementation.md** — Step-by-step guide for implementing UseCases with validation, database access, and repository patterns
  - **docs/TESTING_GUIDE.md** — Quick reference for testing UseCases using `useCaseTestHandler`
- Complete test suite for template project:
  - `template/test/module1/hello_world_test.dart` — 5 tests for HelloWorld use case
  - `template/test/module2/sum_case_test.dart` — 7 tests for SumCase use case
  - `template/test/module2/upper_case_test.dart` — 7 tests for UpperCase use case
  - `template/test/module3/lower_case_test.dart` — 7 tests for LowerCase use case
  - `template/test/module3/multiply_case_test.dart` — 9 tests for MultiplyCase use case
  - All 35 tests demonstrate proper usage of `useCaseTestHandler` with success and failure scenarios

## [0.0.5] - 2025-10-25
### Changed
- `Env` now initializes automatically on first access (lazy singleton pattern). No need to call `Env.init()` explicitly, though it remains available for manual initialization if needed.
- .usecase() now trims leading slashes from usecase names to prevent double slashes in registered paths.

## [0.0.4] - 2025-10-23
### Changed
- `Env` behavior: when a `.env` file is not found the library reads values from `Platform.environment`. If a requested key is missing from both sources an `EnvKeyNotFoundException` is thrown.

## [0.0.3] - 2025-10-23
### Added
- Automatic health endpoint: the server registers `GET /health` which responds with `ok` on startup. Implemented in `modular_api.dart` (exposes `_root.get('/health', (Request request) => Response.ok('ok'));`).

## [0.0.2] - 2025-10-21
### Changed
- refactor: improve OpenAPI initialization (now initialized automatically internally)
- Rename middlewares as examples
- rename example project to template
- Add a simple example

## [0.0.1] - 2025-10-21
### Added
- Initial release of **modular_api**. Main features:
  - Use-case centric framework with `UseCase<I extends Input, O extends Output>` base classes and DTO helpers (`Input`/`Output`).
  - HTTP adapter `useCaseHttpHandler()` to expose UseCases as Shelf `Handler`s.
  - Built-in middlewares: `cors()` and `apiKey()` for CORS handling and header-based API key authentication.
  - OpenAPI/Swagger generation helpers (`OpenApi.init`, `OpenApi.docs`) that infer schemas from DTO `toSchema()`.
  - Utilities: `Env.getString`, `Env.getInt`, `Env.setString` (.env support via dotenv) and `getLocalIp`.
  - Minimal ODBC `DbClient` (DSN-based) exported for database access; example factories and usage provided in `example/` (tested with Oracle and SQL Server; see `NOTICE` for provenance).
  - Example project demonstrating modules and usecases under `example/` and unit-test helpers (`useCaseTestHandler`) under `test/`.
  - Public API exports in `lib/modular_api.dart` for easy consumption.

