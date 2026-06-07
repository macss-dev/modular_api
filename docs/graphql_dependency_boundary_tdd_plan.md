# Engine Integration and External Driver Isolation Plan (TDD-First)

**Status:** Proposed follow-on plan
**Date:** 2026-06-04
**Applies to:** Cross-SDK database-engine integration and external driver isolation for `modular_api`

---

## 1. Purpose

This document defines the staged TDD plan to isolate **external database
drivers** and establish official **database-engine integration packages** across
the Dart, TypeScript, and Python SDKs.

The objective is narrow and pragmatic on purpose.

- A user who installs the modular REST core must not be forced to install an
  external database driver.
- A user who installs the GraphQL-base subsystem must not be forced to install
  an external database driver.
- A user who chooses SQL Server or Postgres should install one official
  engine-integration package and get the MACSS way of integrating that engine
  for both REST and GraphQL.
- A user who starts with REST plus SQL Server or REST plus Postgres should not
  need a package migration later to enable GraphQL on that same engine.

This plan is **not** about removing all unused code. Shipping SQL Server classes
or functions that a given user does not call is acceptable. Most libraries are
used well below 100% of their surface, and carrying unused-but-inert code costs
nothing meaningful at install time.

The only hard line is this:

> The base REST core and the GraphQL-base subsystem must never declare, import
> at module load, or otherwise force the installation of an external database
> driver (for example `mssql`, `dart_odbc`, `pyodbc`, `psycopg`), and must not
> introduce dependency conflicts for users who never touch SQL Server or
> Postgres.

Everything else in this plan exists to enforce that one line cleanly while
shaping the next layer of the MACSS ecosystem.

The engine-agnostic contract for those packages is defined separately in
[db_client_model_spec.md](db_client_model_spec.md).

The full 12-package extension map and delivery order are defined separately in
[twelve_package_development_spec.md](twelve_package_development_spec.md).

### 1.1 Terminology

- **External driver:** a third-party database client library that talks to a
  real database engine (`mssql`, `dart_odbc`, `pyodbc`, `psycopg`, etc.).
- **GraphQL-base:** the GraphQL runtime, parsing, catalog building, SDL
  generation, artifact logic, and provider-neutral contracts, with no external
  driver dependency. (This is what an earlier draft called "GraphQL-neutral".)
- **Engine integration package:** the official MACSS extension for one database
  engine, such as SQL Server or Postgres. It may include connection settings,
  session/pool providers, transaction helpers, health checks, repository and
  result primitives, and GraphQL integration for that engine.
- **Driver adapter:** the narrow code that binds a concrete external driver, or
  an application-owned connection/pool, to the execution contracts inside an
  engine integration package.

---

## 2. Target End State

At the end of this plan, all three SDKs satisfy these conditions.

### 2.1 No forced external driver

- the base `modular_api` artifact in each SDK declares no external database
  driver as a required dependency
- the GraphQL-base subsystem declares no external database driver as a required
  dependency
- importing the base REST core or GraphQL-base never triggers a module-load
  import of an external driver
- an external driver is installed and loaded **only** when the user opts into
  an engine-integration package and uses SQL Server or Postgres

### 2.2 Official engine packages by motor

- the public product model per SDK is `modular_api` plus optional engine
  packages by motor
- the working target package names are:
  - Dart: `modular_api_sqlserver`, `modular_api_postgres`
  - TypeScript: `@macss/modular-api-sqlserver`,
    `@macss/modular-api-postgres`
  - Python: `macss-modular-api-sqlserver`,
    `macss-modular-api-postgres`
- every engine package depends on `modular_api`; `modular_api` never depends on
  an engine package
- a REST application that already uses SQL Server or Postgres installs the same
  engine package it will later use for GraphQL integration

### 2.3 Measured MACSS database architecture in engine packages

- engine packages may be opinionated and include measured infrastructure
  primitives such as connection settings, session/pool providers, transaction
  helpers, health checks, normalized database errors, repository helpers,
  result-style helpers, and GraphQL provider/executor support
- these packages should express the MACSS architectural style, not just ship a
  raw dependency wrapper
- these packages must stay bounded: they are not a general ORM, not a hidden
  query DSL, and not a replacement for application architecture

### 2.4 Driver choice and runtime ownership remain user-aware

- the user may supply an existing connection, session, or pool to the engine
  package
- the engine package may also provide a default session/pool provider when the
  user wants the MACSS default path
- the framework never silently creates a second hidden connection when an
  application-owned one was supplied

### 2.5 No dependency conflicts for non-database users

- a REST-only or GraphQL-base user gets a dependency graph with no external
  driver and therefore no driver version constraints to reconcile
- an engine user accepts the external driver because they explicitly chose that
  engine package
- where a driver is optional, it is declared as an optional/peer/extra
  dependency with a permissive range, not a hard pinned dependency

---

## 3. Architectural Decisions

### 3.1 Official engine packages are part of the product model

For this plan, the ecosystem shape is intentional.

- `modular_api` remains the shared core
- each supported database engine gets one official integration package per SDK
- engine packages are expected to serve both REST database integration and
  GraphQL database integration
- adopting an engine package during REST development should make later GraphQL
  adoption on that engine transparent from a packaging perspective

This is a product decision, not only a packaging workaround.

### 3.2 Isolate the dependency, not necessarily the code

The smallest change that satisfies the objective is to ensure no external driver
is reachable through a required dependency or an eager import. This can be
achieved without splitting every layer into its own published artifact.

Concretely, isolation is achieved by combining these mechanisms, in order of
preference:

1. **Driver-agnostic execution contract.** SQL Server code depends on an
   abstract executor/adapter, never on a concrete driver type.
2. **Lazy driver loading.** The official engine adapter path loads its driver
  at call time (runtime `require`/`import`/deferred import), never at module
  load.
3. **Optional dependency declaration.** The driver is declared as an
   optional/peer/extra dependency, never as a required one.
4. **Physical artifact split — only where a language forces it.** A separate
   artifact is introduced solely when a given SDK cannot otherwise prevent the
   driver from being installed or eagerly loaded.

This is the key difference from the previous draft: artifact splitting is a
**last resort to remove an external dependency**, not a goal in itself. For the
current direction, the preferred split is by **engine package**, not by
GraphQL-only package.

### 3.3 Accepted boundary: an adapter, not a raw connection

The object handed to the SQL Server execution path is a narrow adapter, not a
raw driver connection.

Rationale:

- raw connections leak driver-specific types into shared APIs
- connection shapes vary too much across Dart, Node, and Python
- lifecycle, parameter binding, retries, and row-shape normalization belong in
  adapter code
- adapters are trivial to fake in TDD, which keeps the isolation testable

The user may always wrap an existing application-owned connection or pool in an
adapter. The framework ships one official adapter path per supported engine and
SDK, plus the engine package may expose a MACSS-default provider path as a
convenience.

### 3.4 Measured opinionation inside engine packages

The engine packages may and should be opinionated, but in a bounded way.

Allowed package responsibilities:

- connection settings and environment mapping
- session or pool provider abstractions
- transaction helpers
- normalized database error surfaces
- result-style helpers when they support the MACSS flow cleanly
- repository helpers oriented to MACSS use cases
- health checks and readiness integration
- GraphQL metadata and read integration for that engine

Rejected package scope creep:

- a general ORM layer
- a framework-mandated query DSL for all persistence access
- hiding SQL or the engine too aggressively from the user
- replacing application architecture with a monolithic persistence framework

### 3.5 Rejected boundaries

The following are rejected as required, eagerly-loaded, or base/GraphQL-base
surfaces:

- a required dependency on `mssql`, `dart_odbc`, `pyodbc`, or `psycopg`
- a top-level import of any external driver in base or GraphQL-base code paths
- a public base/GraphQL-base API typed against a concrete driver
  connection/pool (`mssql.ConnectionPool`, `pyodbc.Connection`, `dart_odbc`
  client objects)
- environment-driven auto-connection as a default behavior of base or
  GraphQL-base

### 3.6 Per-SDK isolation mechanism

The mechanism differs by ecosystem because each packaging system enforces
dependencies differently.

- **TypeScript:** the engine package may live as a separate npm package per
  motor or as an internal workspace unit first; its concrete drivers remain
  optional peer dependencies and are loaded lazily.
- **Python:** the engine package may live as a separate distribution per motor
  or as an internal workspace unit first; concrete drivers remain isolated via
  extras and lazy imports.
- **Dart:** this is the strictest case. Dart resolves all `dependencies` in
  `pubspec.yaml` transitively, and has no optional-dependency concept. So the
  engine package split is not just product modeling; it is also the cleanest way
  to keep `dart_odbc` and the future Postgres driver out of the base
  `modular_api` package.

### 3.7 Package map and dependency direction

The intended dependency direction is:

- application -> `modular_api`
- application -> chosen engine package(s)
- engine package -> `modular_api`
- engine package -> concrete driver(s)

It must never be:

- `modular_api` -> engine package

Working package targets:

- Dart: `modular_api_sqlserver`, `modular_api_postgres`
- TypeScript: `@macss/modular-api-sqlserver`,
  `@macss/modular-api-postgres`
- Python: `macss-modular-api-sqlserver`,
  `macss-modular-api-postgres`

### 3.8 Minimal package impact

Relative to today's single base artifact per SDK, the realistic outcome is:

- **TypeScript:** likely two engine packages over time, one per supported motor,
  but no additional driver-only package is required.
- **Python:** likely two engine packages over time, one per supported motor,
  but no additional driver-only package is required.
- **Dart:** two engine packages are the preferred shape, one for SQL Server and
  one for Postgres, because that keeps both concrete drivers out of the base
  `pubspec.yaml` while matching the chosen product model.

So the expected net change is **engine packages by motor**, with Dart receiving
the strongest packaging benefit from that choice.

### 3.9 Security invariants

The isolation must preserve these rules.

- adapters execute structured commands; they do not build SQL from raw user
  input
- SQL generation and parameterization stay in the provider/compiler code
- execution flows pass structured commands across the adapter boundary rather
  than interpolated SQL fragments
- no adapter widens privileges by silently creating a framework-owned
  connection when an application-owned connection was supplied

### 3.10 Versioning and 0.x policy

- the project is in 0.x, so clean cuts are preferred over long deprecation
  windows
- any new engine package follows the synchronized-versioning policy in
  [ADR-0002](adr/0002-synchronized-versioning-across-sdks.md) when it becomes
  externally published; during 0.x it may start as a workspace-local package
- optional/peer/extra driver dependencies use permissive ranges to avoid
  conflicts, not hard pins

---

## 4. Delivery Strategy

The work is split into three milestones.

### Milestone A — Establish engine packages and isolate the driver

Per SDK, ensure no external driver is a required dependency and no
base/GraphQL-base code imports a driver at module load, while defining the
official engine package entrypoints.

### Milestone B — Add measured MACSS engine architecture

Introduce the bounded opinionated architecture inside the engine packages:
session or pool provider, normalized errors, result/repository helpers, and the
adapter contracts needed for SQL execution.

### Milestone C — Complete GraphQL integration on top of the same engine package

Ensure GraphQL uses the same chosen engine package so REST-first users later
enable GraphQL without changing package selection, then add CI guards that fail
if a driver reappears in base or GraphQL-base.

### Lead SDK sequence

- **Dart leads**, because its packaging is the strictest and because the engine
  package split is mandatory there for a clean outcome.
- TypeScript is mostly a verification pass since the pattern already exists.
- Python ports the engine-package shape and lazy-load hardening after Dart.

---

## 5. TDD Operating Rules

Every story follows this order:

1. Write one failing isolation or behavior-preservation test.
2. Write the narrowest additional failing tests needed to localize the change.
3. Implement the smallest production change to make the red set pass.
4. Refactor only after the red set is green.
5. Port the same slice to the other SDKs before advancing.

Mandatory rules:

- no slice closes while the base artifact or GraphQL-base declares an external
  driver as a required dependency
- no slice closes while any base/GraphQL-base module imports an external driver
  at load time
- no public base/GraphQL-base API is typed against a concrete driver
  connection/pool
- the official engine adapter path loads its driver lazily and reports a clear,
  actionable error when the driver is absent
- adapters execute structured commands only; they never build SQL from raw user
  input
- driver dependencies are declared optional/peer/extra with permissive ranges

### Required test layers

- **characterization tests** freeze current REST, GraphQL, and SQL Server
  behavior before changes
- **driver-isolation guard tests** fail if a manifest declares a required driver
  dependency or if a base/GraphQL-base module imports a driver at load time
- **missing-driver tests** assert a clear error when the driver is not installed
- **adapter contract tests** prove an application-owned connection/pool is
  reused through the adapter
- **integration tests** run the full SQL Server path against the shared fixture
  using the official engine adapter path
- **clean-room install/import tests** prove base and GraphQL-base install and
  import with no external driver present

---

## 6. Success Criteria

The plan is complete only when all of these are true.

- the base REST core in every SDK installs with no external database driver in
  its required dependency graph
- the GraphQL-base subsystem in every SDK installs with no external database
  driver in its required dependency graph
- no base/GraphQL-base module imports an external driver at module load
- the SQL Server engine package in every SDK owns its concrete driver
  dependency and keeps it out of the base package
- the Postgres engine package in every SDK owns its concrete driver dependency
  and keeps it out of the base package
- application-owned connections, sessions, or pools can be reused through the
  engine package boundary
- each engine package exposes the measured MACSS integration surface agreed for
  v1: connection/session provider, normalized errors, repository/result helpers,
  health hooks, and GraphQL integration
- the full SQL Server path reproduces current v1 behavior through the engine
  package
- a REST-only or GraphQL-base user has no external driver version constraints to
  reconcile

---

## 7. Stage Plan

### Stage 0 — Characterization and Red Isolation Guards

**Goal:** freeze current behavior and make the current driver coupling
executable as failing tests.

**Tests written first:**

- current REST, GraphQL, and SQL Server smoke tests stay green in each SDK
- a driver-isolation guard test per SDK initially fails where a driver is a
  required dependency or eagerly imported
- a clean-room base/GraphQL-base import test initially fails where a driver load
  is triggered

**Production scope:**

- inventory every place each SDK declares or imports an external driver
- decide, per SDK, the engine-package names and package boundaries for SQL
  Server and Postgres
- decide, per SDK, which isolation mechanism applies inside each engine package
  (optional/peer, extras, lazy load, or separate package boundary)
- add CI harnesses for clean-room install/import without a driver

**Exit criteria:**

- current behavior is frozen by tests
- at least one red test per SDK proves the driver is not yet isolated
- the per-SDK isolation mechanism is agreed
- the SQL Server and Postgres engine package shape is agreed

### Stage 1 — Engine Package Skeletons and Shared Contracts

**Goal:** introduce the engine packages and the shared contracts they need so
database integration no longer lives in the base package.

**Tests written first:**

- the SQL Server and Postgres engine package roots compile and export only their
  intended public surfaces
- the SQL Server execution path runs against a fake adapter with no driver
  present
- a guard test fails if the contract references a concrete driver type
- an adapter contract test proves an application-owned connection/pool is
  accepted

**Production scope:**

- create the engine package skeletons for SQL Server and Postgres
- define the narrow executor/adapter contract (execute structured command,
  return rows)
- move or expose the shared contracts needed by REST and GraphQL integration
- keep SQL generation/parameterization in provider code, behind the boundary

**Exit criteria:**

- database integration no longer needs to live in the base package by design
- no concrete driver type appears in shared APIs

### Stage 2 — Measured MACSS Engine Infrastructure

**Goal:** add the bounded opinionated infrastructure that defines the engine
package as part of the MACSS ecosystem instead of a thin driver wrapper.

**Tests written first:**

- a session/pool provider contract test proves both framework-owned and
  application-owned resource paths behave correctly
- normalized error tests prove database failures map to stable package-level
  error shapes
- repository/result helper tests prove the chosen abstractions stay thin and do
  not replace application architecture

**Production scope:**

- add connection settings plus session or pool providers per engine
- add normalized database errors
- add measured result and repository helpers aligned with the MACSS style
- add health check and readiness integration for each engine package

**Exit criteria:**

- engine packages expose the agreed bounded MACSS infrastructure surface
- the package does useful REST integration work even before GraphQL is enabled

### Stage 3 — Lazy Driver Loading and Driver Isolation

**Goal:** ensure the driver is never loaded at module load and never a required
dependency.

**Tests written first:**

- a missing-driver test asserts a clear, actionable error
- a guard test fails if any base/GraphQL-base module imports the driver at load
  time
- a manifest test fails if the driver is declared as a required dependency

**Production scope:**

- load the driver lazily inside the engine package's concrete adapter path
  (runtime `require`/`import`/deferred import)
- declare the driver as optional/peer (TypeScript), extra (Python), or keep it
  confined to the engine package boundary (Dart)
- normalize the missing-driver error message across SDKs

**Exit criteria:**

- importing base/GraphQL-base triggers no driver load
- the driver is optional/peer/extra (TS, Python) or absent from the base
  package because it lives in the engine package (Dart)

### Stage 4 — Dart Engine Package Extraction

**Goal:** remove `dart_odbc` and the future Postgres driver from the base
`modular_api` `pubspec.yaml` by finishing the Dart engine packages.

**Tests written first:**

- the base Dart package builds and tests green with no SQL Server or Postgres
  driver dependency
- the SQL Server engine package builds in isolation with its `dart_odbc`
  dependency
- the Postgres engine package builds in isolation with its chosen driver
  dependency
- an integration test reproduces current SQL Server behavior through the SQL
  Server engine package

**Production scope:**

- create the Dart engine packages (working names `modular_api_sqlserver` and
  `modular_api_postgres`)
- move the `dart_odbc` binding and any Postgres-driver binding into those
  packages
- move database integration surfaces out of the base package root and into the
  engine package roots
- update Dart examples to depend on engine packages explicitly

**Exit criteria:**

- `dart_odbc` no longer appears in the base `pubspec.yaml`
- the future Postgres driver no longer needs to appear in the base
  `pubspec.yaml`
- the full SQL Server path works through `modular_api_sqlserver`
- REST-only and GraphQL-base Dart users install no engine driver unless they
  choose an engine package

### Stage 5 — GraphQL Integration on Top of the Same Engine Package

**Goal:** ensure GraphQL uses the same engine package already chosen for REST
integration.

**Tests written first:**

- a REST-plus-engine example later enables GraphQL without changing package
  selection
- GraphQL integration tests prove metadata and read execution come from the same
  engine package APIs used for REST database integration

**Production scope:**

- wire GraphQL metadata and read execution through each engine package
- expose convenience helpers such as `createSqlServerGraphqlSupport(...)` and
  `createPostgresGraphqlSupport(...)` where appropriate
- ensure GraphQL activation is configuration-driven, not package-migration
  driven

**Exit criteria:**

- a REST user already on an engine package can enable GraphQL transparently on
  that same engine package
- engine-package adoption is the only package decision needed for both REST and
  GraphQL on a chosen engine

### Stage 6 — Docs, Examples, and Consumer Migration

**Goal:** make the supported usage explicit and migrate consumers.

**Tests written first:**

- example apps in all three SDKs compile and run with explicit engine-package
  composition
- downstream consumer smoke covers the MACSS CLI SQL Server path

**Production scope:**

- update READMEs and guides to show: install the engine package for SQL Server
  or Postgres, then use the MACSS engine integration surface for REST and
  GraphQL
- migrate examples and the MACSS CLI to engine-package composition

**Exit criteria:**

- documented usage shows engine-package installation as the explicit step for
  database-backed apps
- consumers build with no driver in REST-only or GraphQL-base scenarios

### Stage 7 — CI Enforcement and Release

**Goal:** make driver re-coupling hard to reintroduce.

**Tests written first:**

- CI validates clean-room base install/import with no driver in all SDKs
- CI validates clean-room GraphQL-base install/import with no driver in all SDKs
- CI validates the full SQL Server path with the engine package in all SDKs
- a dependency audit fails if base or GraphQL-base gains a required driver
  dependency or eager driver import

**Production scope:**

- add the CI guardrails and dependency audits
- add migration notes and version-bump strategy (including the new engine
  packages where applicable)

**Exit criteria:**

- isolation is enforced automatically by CI
- published artifacts carry no external driver in base or GraphQL-base

---

## 8. Cross-SDK Acceptance Matrix

Every stage closes only when the affected SDKs are green.

- Stage 0-3: base and GraphQL-base tests in Dart, TypeScript, and Python, plus
  clean-room no-driver install/import smoke
- Stage 4: Dart base without `dart_odbc`, plus the SQL Server engine package
  integration test against the shared SQL Server fixture
- Stage 5-7: full SQL Server path with the engine package per SDK, plus the
  MACSS CLI downstream smoke

A test must not require an engine package to exist before the plan has
introduced it.

---

## 9. Non-Goals

This plan does not attempt the following in the same refactor.

- removing inert, dependency-free SQL Server code just because some users do not
  call it
- splitting every layer into its own published artifact for purity
- redesigning the GraphQL query contract
- changing the canonical artifact format
- building a full ORM or generic persistence framework unrelated to the MACSS
  style

---

## 10. Review Checklist

Use this before implementation begins.

- Is the team aligned that the objective is isolating **external drivers**, not
  removing unused code?
- Is the team aligned that REST-only and GraphQL-base users must not get an
  external driver in their required dependency graph?
- Is the team aligned that inert, driver-free SQL Server code may remain in a
  shared artifact?
- Is the team aligned that the public ecosystem shape is `modular_api` plus one
  official engine package per supported motor?
- Is the team aligned that a REST app should adopt the same engine package it
  will later use for GraphQL on that engine?
- Is the team aligned on the measured opinionated scope inside engine packages:
  session/pool provider, normalized errors, result/repository helpers, health,
  and GraphQL integration, but not a full ORM?
- Is the team aligned that the accepted boundary is adapter-based, not
  connection-based?
- Is the team aligned that Dart gets the strongest packaging benefit from the
  engine-package split?
- Is the team aligned that drivers are declared optional/peer/extra with
  permissive ranges to avoid conflicts?
- Is the MACSS CLI migration treated as a required downstream acceptance gate?
