# DB Client Model Specification

**Status:** Proposed
**Date:** 2026-06-04
**Applies to:** Cross-SDK engine integration model for Dart, TypeScript, and Python

---

## 1. Purpose

This document defines one engine-agnostic specification for the `db_client`
model used by the MACSS ecosystem.

The purpose of this model is to standardize how `modular_api` integrates with
database engines such as SQL Server and Postgres without forcing database
drivers into the base package and without making GraphQL a separate packaging
decision from REST database integration.

The model is designed so that:

- a REST application can adopt one engine package early
- the same engine package can later enable GraphQL without a package migration
- the engine package can express the MACSS architectural style in a measured,
  reusable way
- the base `modular_api` package remains free of concrete database drivers

This specification is intentionally independent from any one motor, driver, or
SDK language.

---

## 2. Naming Scope

This document specifies the **model** name `db_client`.

It does **not** freeze the final published branding of the engine packages.
Possible published names include:

- `db_client_sqlserver`, `db_client_postgres`
- `macss_sqlserver`, `macss_postgres`
- `modular_api_sqlserver`, `modular_api_postgres`

For the rest of this specification, `db_client_<engine>` is used as the neutral
placeholder family name.

---

## 3. Product Model

The intended product shape is:

- `modular_api` = core HTTP, use cases, middleware, health base, metrics base,
  and GraphQL-base contracts/runtime-neutral seams used by the future optional
  GraphQL plugin
- `db_client_sqlserver` = official SQL Server engine integration package
- `db_client_postgres` = official Postgres engine integration package

Each engine package is an optional extension over `modular_api`.

Dependency direction must always be:

- application -> `modular_api`
- application -> chosen engine package(s)
- engine package -> `modular_api`
- engine package -> concrete database driver(s)

Dependency direction must never be:

- `modular_api` -> engine package

This rule is what keeps external database drivers out of the base package.

---

## 4. Design Goals

The `db_client` model has these goals.

- Provide one official MACSS integration package per engine.
- Keep concrete database drivers out of the base `modular_api` package.
- Let REST-first users adopt the engine package once and reuse it later for
  GraphQL.
- Support both application-owned and framework-owned session or pool lifecycles.
- Provide a consistent Result and Repository style across SDKs.
- Provide health and operational integration appropriate for server workloads.
- Keep GraphQL integration on top of the same engine package instead of forcing
  a second package choice later.

---

## 5. Non-Goals

The `db_client` model is not intended to become:

- a database driver implementation from scratch
- a generic ORM
- a framework-mandated query DSL for all persistence access
- a replacement for application architecture
- a requirement for REST-only applications that do not use a database engine

The engine package is an opinionated integration layer, not an entire
persistence universe.

---

## 6. Core Principles

### 6.1 Engine package, not raw driver, is the product surface

Applications should depend on an engine package, not on direct driver
integration logic scattered through the app.

### 6.2 The engine package may be opinionated

The engine package is allowed to encode MACSS opinions such as Result,
Repository, health integration, and session management.

### 6.3 Opinionation must be bounded

The package should help applications move faster, but must not trap them behind
opaque abstractions that hide the engine too aggressively.

### 6.4 Session or pool ownership must be explicit

If the application supplies an existing connection, session, or pool, the engine
package must reuse it and must not silently allocate a second hidden resource.

### 6.5 GraphQL integration must reuse the same engine package

If an application already chose `db_client_sqlserver` or `db_client_postgres`
for REST data access, GraphQL should build on that same package.

### 6.6 Concrete drivers stay behind the engine boundary

The driver is a private implementation detail of the engine package, not part of
the shared `modular_api` core contract.

---

## 7. Model Layers

Each `db_client_<engine>` package is built from five conceptual layers.

### 7.1 Configuration layer

Defines engine-specific connection settings and environment mapping.

Examples:

- host, port, database, username, password
- TLS or encryption settings
- pool sizing settings
- command and connection timeouts

### 7.2 Resource layer

Owns how sessions, connections, and pools are acquired and released.

This layer must support two modes:

- package-owned resource lifecycle
- application-owned resource reuse

### 7.3 Execution layer

Owns parameterized command execution, row materialization, transaction helpers,
and normalized failures.

### 7.4 Repository layer

Owns the MACSS repository helpers and the Result-oriented persistence style.

This layer standardizes repository primitives used by applications. Concrete
repositories still remain application- or domain-specific code outside the
engine package.

This layer should make the common path ergonomic while still letting advanced
users drop down to direct command execution when needed.

### 7.5 GraphQL integration layer

Owns metadata introspection and read execution needed by the `modular_api`
GraphQL subsystem for that engine.

---

## 8. Core Abstract Contracts

The following contracts are engine-agnostic. Each engine package implements them
using its concrete driver.

### 8.1 Connection settings

`DbConnectionSettings`

Responsibilities:

- capture the engine connection configuration
- normalize environment-derived configuration
- support safe redaction for logs and diagnostics

Required properties:

- `engineId`
- `database`
- `redactedSummary`

Optional properties by engine:

- `host`
- `port`
- `username`
- `password`
- `sslMode`
- `options`

### 8.2 Session provider

`DbSessionProvider`

Responsibilities:

- acquire a session or connection lease
- optionally own a pool
- expose lifecycle hooks for close or shutdown

Conceptual contract:

```text
acquire() -> DbResult<DbSessionLease>
close() -> DbResult<void>
describe() -> DbProviderDescription
```

### 8.3 Session lease

`DbSessionLease`

Responsibilities:

- expose the active session abstraction
- know whether the resource is application-owned or package-owned
- release only when the package owns the lease

Conceptual contract:

```text
session
ownedByPackage
release() -> DbResult<void>
```

### 8.4 Command model

`DbCommand`

Responsibilities:

- represent a parameterized database operation
- keep SQL text and parameters together
- expose intent for diagnostics and tracing

Required fields:

- `kind` = `query | execute | batch | scalar`
- `text`
- `parameters`
- `label`

### 8.5 Command executor

`DbCommandExecutor`

Responsibilities:

- execute parameterized commands against a session
- return normalized rows or execution summaries
- never expose concrete driver rows directly

Conceptual contract:

```text
query(command) -> DbResult<DbRowSet>
execute(command) -> DbResult<DbExecutionSummary>
scalar(command) -> DbResult<DbScalar>
```

### 8.6 Transaction runner

`DbTransactionRunner`

Responsibilities:

- run work in a transaction
- commit on success
- rollback on failure
- preserve normalized error semantics

Conceptual contract:

```text
run(body, options?) -> DbResult<T>
```

### 8.6.1 Normalized success payloads

The `db_client` family must not return raw driver rows or ad-hoc execution
summaries as its shared success surface.

Minimum shared success payload contracts:

`DbRowSet`

Required fields:

- `rows`
- `metadata`

Recommended metadata fields:

- `rowCount`
- `duration`
- `commandLabel`

`DbExecutionSummary`

Required fields:

- `affectedCount`
- `metadata`

Recommended metadata fields:

- `duration`
- `commandLabel`

`DbScalar`

Required fields:

- `value`
- `metadata`

Recommended metadata fields:

- `duration`
- `commandLabel`

### 8.7 Result model

`DbResult<T>`

`DbResult` is the canonical success or failure container for engine-package
operations.

Required properties:

- `isSuccess`
- `value` when successful
- `failure` when unsuccessful

Required helpers:

- `map`
- `flatMap`
- `mapFailure`
- `getOrThrow`

SDK-specific shape may vary:

- Dart: sealed class or sealed result hierarchy
- TypeScript: discriminated union
- Python: tagged dataclass or typed union

### 8.8 Failure model

`DbFailure`

Responsibilities:

- normalize driver-specific failures into a stable MACSS taxonomy
- preserve diagnostics useful for logs, retries, and HTTP translation

Required fields:

- `kind`
- `code`
- `message`
- `retryable`
- `transient`
- `details`

Minimum required kinds:

- `connectivity`
- `timeout`
- `authentication`
- `authorization`
- `constraint`
- `conflict`
- `notFound`
- `serialization`
- `cancelled`
- `unknown`

### 8.9 Public facade

`DbClient`

Responsibilities:

- provide one ergonomic root facade for direct engine operations
- compose session acquisition, command execution, transaction helpers, and
  repository-context creation
- keep raw driver types out of the public entry path

Conceptual contract:

```text
query(command) -> DbResult<DbRowSet>
execute(command) -> DbResult<DbExecutionSummary>
scalar(command) -> DbResult<DbScalar>
transaction(body, options?) -> DbResult<T>
repositoryContext() -> DbRepositoryContext
close() -> DbResult<void>
describe() -> DbProviderDescription
```

Rules:

- engine package roots SHOULD expose `DbClient` or an equivalent root facade
- the facade must delegate to `DbSessionProvider`, `DbCommandExecutor`, and
  `DbTransactionRunner` rather than introducing a second execution model
- the facade must preserve `DbResult<T>` and `DbFailure` semantics

### 8.10 Repository context

`DbRepositoryContext`

Responsibilities:

- bundle the execution primitives needed by repositories
- remove direct driver access from repository code

Required members:

- `sessionProvider`
- `commandExecutor`
- `transactionRunner`

### 8.11 Repository base

`DbRepository`

Responsibilities:

- provide thin helper methods for common repository operations
- enforce Result-oriented persistence flow
- keep repository code aligned with MACSS without becoming a hidden ORM

Repository rules:

- repositories stay application- or domain-specific
- repositories may execute engine SQL explicitly
- repositories should return `DbResult<T>` or a domain alias built on it
- repositories must not depend on concrete driver types
- the engine package provides repository primitives, not the application's
  concrete repositories

### 8.12 Health integration

`DbHealthContributor`

Responsibilities:

- expose a health probe suitable for `modular_api`
- validate connectivity and, where appropriate, pool health
- produce operationally meaningful output without leaking secrets

Required outputs:

- status
- response time
- redacted output summary

### 8.13 GraphQL support bundle

`DbGraphqlSupport`

Responsibilities:

- expose the engine-specific metadata and read integration required by
  `modular_api` GraphQL
- let GraphQL activate without asking the user to install a second engine
  package

Required members:

- `catalogProvider`
- `readExecutor`
- `healthContributor` or health hook when needed

Optional members:

- `sourceDigestFactory`
- `artifactLoader`
- `capabilityRegistration`

---

## 9. Pool and Session Model

The public abstraction should be **session provider first**, not **pool first**,
because not every engine or driver has the same pooling semantics.

However, pooling is still a first-class concern for server applications.

Therefore:

- the engine package may implement `DbSessionProvider` on top of a pool
- the engine package may expose pool-specific settings and telemetry
- the engine package root should prefer the neutral `DbSessionProvider`
  abstraction
- raw driver pool types should remain outside the shared public contracts

This gives a stable cross-engine model while still supporting the practical
needs of production server apps.

---

## 10. Result Pattern Rules

The Result pattern is part of the `db_client` model.

Rules:

- all direct engine-package execution operations return `DbResult<T>`
- repository helpers return `DbResult<T>` or an alias preserving the same
  semantics
- failures are structured through `DbFailure`, not arbitrary driver exceptions
- success payloads preserve normalized metadata through `DbRowSet`,
  `DbExecutionSummary`, or `DbScalar`
- bridge helpers may convert `DbResult<T>` into application exceptions when the
  app chooses that style

The Result pattern is meant to standardize persistence flow, not to force the
entire `modular_api` ecosystem to abandon every exception-based API.

---

## 11. Repository Pattern Rules

The Repository pattern is part of the `db_client` model, but it must stay thin.

Rules:

- one repository should represent one aggregate, entity family, or bounded
  persistence slice
- repositories should depend on `DbRepositoryContext`, not on raw drivers
- repositories may use explicit SQL or engine-native parameterized commands
- repositories should map rows to domain DTOs or persistence models clearly
- repositories must not become a generic hidden query builder

The engine package may provide:

- repository base classes
- row mapping helpers
- pagination helpers
- transaction-scoped repository context helpers

The engine package must not attempt to generate every repository automatically.

---

## 12. GraphQL Integration Rules

The GraphQL integration inside `db_client_<engine>` must satisfy these rules.

- it must build on the same engine package already used by REST integration
- it must expose the metadata and read execution pieces required by
  `modular_api` GraphQL
- it must not force the application to install another package just to turn on
  GraphQL for that same engine
- it must respect the external-driver isolation rule for base and GraphQL-base

This means GraphQL is an additional capability of the chosen engine package, not
a separate product branch.

---

## 13. Operational Integration Rules

Each engine package should provide measured operational integration.

Required operational capabilities:

- database health check
- startup validation support
- resource close or shutdown support
- redacted diagnostics

Recommended operational capabilities:

- pool metrics
- connection wait or saturation telemetry
- transaction timing metrics
- structured logging hooks

---

## 14. SDK Mapping

The model is shared across SDKs, but each language should expose it in an
idiomatic way.

| Concept | Dart | TypeScript | Python |
| --- | --- | --- | --- |
| Async result | `Future<DbResult<T>>` | `Promise<DbResult<T>>` | `Awaitable[DbResult[T]]` |
| Result type | sealed class | discriminated union | tagged dataclass or typed union |
| Shared contracts | abstract class / interface | interface / abstract class | Protocol / ABC |
| Session provider | class with async methods | interface plus concrete class | protocol plus concrete class |
| Repository base | abstract base class | abstract class | base class or mixin |

The semantic contract should match even when syntax differs.

---

## 15. Engine Package Responsibilities

Each engine package must implement the `db_client` model for one engine.

### 15.1 `db_client_sqlserver`

Must provide:

- SQL Server connection settings
- SQL Server session or pool provider
- SQL Server command executor
- SQL Server transaction runner
- SQL Server normalized failures
- SQL Server repository helpers
- SQL Server health contributor
- SQL Server GraphQL support

### 15.2 `db_client_postgres`

Must provide:

- Postgres connection settings
- Postgres session or pool provider
- Postgres command executor
- Postgres transaction runner
- Postgres normalized failures
- Postgres repository helpers
- Postgres health contributor
- Postgres GraphQL support

---

## 16. External Driver Rules

The handling of drivers must follow these rules.

- `modular_api` must not depend on concrete database drivers
- engine packages own concrete drivers
- the engine package loads the driver lazily where the language permits
- the engine package reports a clear, actionable error when the driver is
  missing
- driver-specific public types must not leak into shared cross-engine contracts

SDK-specific expectation:

- Dart: the engine package boundary is the primary way to keep the driver out of
  the base package
- TypeScript: engine packages may also use optional peer dependencies and lazy
  loading
- Python: engine packages may also use extras and lazy imports

---

## 17. Acceptance Criteria for Any Engine Implementation

An engine package conforms to this specification only when all of these are
true.

- a REST-only app can use `modular_api` without installing that engine's driver
- an app using the engine package gets one coherent MACSS integration surface
- the package supports package-owned and application-owned resource paths
- direct execution APIs return `DbResult<T>` with normalized `DbFailure`
- repository helpers are present and thin
- health integration is present
- GraphQL integration is present on the same engine package
- no shared public contract depends on a concrete driver type

---

## 18. Build Order

The intended build order is:

1. Define the `db_client` abstract model and tests.
2. Implement `db_client_sqlserver` in Dart first.
3. Port the same model to TypeScript and Python.
4. Implement `db_client_postgres` after the SQL Server path proves the model.
5. Wire GraphQL integration onto the same engine packages.

This keeps the ecosystem coherent while still respecting the packaging reality
of each SDK.
