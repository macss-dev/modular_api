# modular_api - Product Roadmap



---

## Versioning Philosophy

Every release must be coherent on its own.

- **Major** - breaking changes to the core contract or plugin contract
- **Minor** - new capabilities, new public APIs
- **Patch** - bug fixes, documentation, and performance improvements

**Up to `1.0.0`, releases refine, harden, and consolidate the surfaces that already shipped, with
two deliberate exceptions** — tracing and gRPC, each a **minor** under the rules above (new
capability, new public API), each justified in an ADR before implementation. `1.0.0` is the point
at which the ecosystem is declared stable for long-term support. The bar for admitting anything
else to that list is an ADR that explains why it is foundational rather than convenient.

A consequence worth stating explicitly: some improvements *reduce* surface rather than add it.
For example, converging the six database packages (`sqlserver` + `postgres` across the three SDKs)
into a single `modular_api_sql` contracts package per SDK — dropping the count from 15 packages to
12 — is an improvement of what already exists, not a new feature. We do not commit to a version
number for that change; it lands when it is ready, under the same semver rules.

---

## Current State - 0.6.0

`modular_api` provides, verified across Dart, TypeScript, and Python:

- A modular REST API model based on modules, DTOs, and use cases
- A public plugin host with deterministic lifecycle orchestration (setup, validation, freeze,
  shutdown) and three ordered middleware slots (`preRouting`, `preHandler`, `postHandler`)
- Host-owned plugin-pipeline guardrails: attributable middleware short-circuits in request logs
  and structured JSON `500` responses for uncaught plugin-pipeline failures
- Official `HealthPlugin`, `MetricsPlugin`, `OpenApiPlugin`, and `DocsPlugin` under the shared
  `basePath`, plus plugin routes that are first-class in OpenAPI and metrics (ADR-0003)
- An official GraphQL runtime plugin mounted at `/{basePath}/graphql`, with catalog, metadata,
  SDL, artifact, and SQL Server read-compiler surfaces
- Fifteen ecosystem packages: core SDK, REST client, GraphQL client, SQL Server, and Postgres —
  one of each per SDK — released under a single coordinated version (ADR-0002)
- Contracts-only database packages (ADR-0004): engine-agnostic `DbClient`, repository, and
  transaction contracts, with typed command parameters (`DbParameter`) and stored-procedure
  support (`DbCommandKind.procedure`, `DbProcedureOutcome`) as of 0.6.0
- Request-scoped structured logging and cross-language parity tests across the three SDKs

---

## History-Based Timeline

```
0.4.5  Schema/OpenAPI/CORS/logging parity hardening across Dart, TypeScript, and Python
0.4.6  Synchronized SDK versioning policy and package-layout cleanup
0.4.7  Plugin host guardrails, official runtime plugins, GraphQL runtime, and complementary packages
0.4.8  Flutter web compatibility (rest_client rewritten to package:http); first full end-to-end
       verification (PostgreSQL + Dart + Flutter web + 41/41 Playwright tests)
0.5.0  Ecosystem-wide coordinated bump of all packages; docs/contracts aligned with shipped state;
       semver enforced from this version forward (ADR-0002)
0.6.0  Database contract hardening: typed parameters and stored-procedure support, contracts-only
       stance formalized (ADR-0004)
```

---

## The Road to 1.0.0

All of these land under semver when ready; no version numbers are pre-assigned. The first two are
new capabilities (minor releases, per ADR-0005); the rest are improvements of the existing
architecture.

- **Distributed tracing in core, speaking OTLP** (ADR-0005). Completes the observability surface
  alongside logging and metrics. Own contract (`ModularTracer` / `Span`), no OpenTelemetry
  dependency, OTLP/HTTP with JSON encoding as the wire format, `SpanExporter` as a swappable
  contract behind a conditional import. Span lifecycle is host-owned and transport-neutral; the
  official opt-in plugin owns configuration, sampling, batching, export, and shutdown flush.
  Instrumentation reaches `modular_api_postgres` (around `DbCommand`) and
  `modular_api_rest_client` (client span plus `traceparent` injection), so the release is
  coordinated across packages.
- **gRPC as a third transport**, after tracing. The use-case core already projects to two
  surfaces — OpenAPI generated from use cases, GraphQL SDL from metadata — and protobuf is a
  natural third projection of the same model: *one use case, N transports*. Unlike tracing, this
  one **does** take libraries (`grpc`, `protobuf`, and `protoc` codegen), consistent with the
  principle that the framework owns contracts and semantics but delegates transports — `shelf`
  serves HTTP today on exactly those terms. Tracing is designed to accommodate it: a new transport
  arrives as an adapter over the neutral span lifecycle, not as a refactor. Scope to settle when
  the ADR is written: whether the gRPC service surface is generated from use-case schemas or
  declared, and whether streaming is in the first slice.
- **Converge the database packages** toward a single `modular_api_sql` contracts package per SDK
  (and, later, `modular_api_nosql`), since the per-engine contracts differ only in
  `DbConnectionSettings`. Reduces 15 packages to 12. (ADR-0004)
- **Align the Python database contracts to async**, matching the ASGI core (issue #23).
- **Remove the `dart_odbc` dependency** from the Dart `modular_api_sqlserver` package so it stays
  contracts-only; driver-backed schema introspection becomes the consumer's responsibility or a
  docs example (issue #24).
- **Migrate the generated spec to OpenAPI 3.1** when the compatibility work is ready.
- **Strengthen CI/CD and contributor experience**: per-language style and contribution guides,
  broader cross-language plugin and GraphQL compatibility tests.
- **Document the optional CQRS profile** (REST commands + GraphQL queries) and keep REST-only APIs
  a first-class supported mode in examples and docs.

---

## Invariants

These do not change across releases:

1. The core stays minimal.
2. Official plugins use the same public contract as third-party plugins.
3. REST-only APIs remain valid with or without optional plugins.
4. `/{basePath}/docs` stays the canonical interactive documentation endpoint.
5. CQRS is optional and only active when the GraphQL plugin is enabled.
6. Database packages are contracts-only; the framework ships no driver binding (ADR-0004).
7. Telemetry emits open formats and nothing vendor-specific: the framework carries no cloud
   exporter and no cloud credentials. Reaching a backend is the deployment's concern (ADR-0005).
8. The framework owns contracts and semantics, and delegates transports to libraries.
