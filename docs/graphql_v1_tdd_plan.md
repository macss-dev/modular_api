# GraphQL V1 Implementation Plan (TDD-First)

**Status:** Proposed implementation plan
**Date:** 2026-06-02
**Applies to:** SQL Server-first GraphQL rollout for `modular_api`

---

## 1. Purpose

This document defines the staged implementation plan for the GraphQL v1 design.
The plan is explicitly **TDD-first**: each stage begins by writing executable
tests that define the contract, then implementing the minimum code needed to
make those tests pass, and only then refactoring.

The plan assumes the design decisions already closed in the architecture and
contract documents:

- strict allowlist publication
- runtime-first first delivery
- SQL Server is the only engine in scope for v1 execution; PostgreSQL follows
  after the SQL Server path is stable
- governed publication intent from SQL tree + sidecar, with SQL Server v1
  physical shape derived from real engine metadata
- deterministic conservative naming
- canonical `sourceDigest`
- formal GraphQL query surface
- provider-compiled read commands executed through `SqlReadExecutor`
- fail-fast startup and shared health reporting

Post-v1 external database-driver isolation is tracked separately in
[graphql_dependency_boundary_tdd_plan.md](graphql_dependency_boundary_tdd_plan.md).

---

## 2. Delivery Strategy

The rollout is split into two milestones.

### Milestone A — Runtime-First Usable Delivery

The application can start, introspect SQL Server metadata, apply sidecar
governance, build the catalog, generate the GraphQL schema, serve the endpoint,
and report GraphQL through the shared health surface.

Stages included:

1. Stage 1 — Physical model introspection
2. Stage 2 — Sidecar parsing and governance validation
3. Stage 3 — Catalog builder, naming, and `sourceDigest`
4. Stage 4 — GraphQL schema generation contract
5. Stage 5 — Read command compilation and executor seam
6. Stage 6 — Runtime integration, fail-fast startup, and health
7. Stage 7 — Runtime hardening and anti-N+1 validation

### Milestone B — Compile Mode and Artifacts

The same provider/catalog pipeline is reused at build time to emit `catalog.json`,
`catalog.lock`, `diagnostics.json`, and `schema.graphql`.

Stage included:

8. Stage 8 — Compile mode and artifact emission

### Confirmed execution constraints

- shared local test infrastructure for v1 lives under `code/infra/docker`
- `.devcontainer` remains an optional developer convenience and is not part of
  the v1 test or runtime contract
- integration tests use one shared SQL Server 2019 container with real
  metadata; database behavior is not mocked
- test isolation must come from recreating or resetting the logical test
  database state, not from relying on one long-lived dirty database
- shared SQL fixtures should be reusable across SDKs even when the test
  harnesses remain language-specific

---

## 3. TDD Operating Rules

Every story inside every stage follows this order:

1. Write one failing acceptance or contract test.
2. Write the narrowest additional failing unit or integration tests needed to
   localize the behavior.
3. Implement the minimum production code required to make the tests pass.
4. Refactor only after the entire red set is green.
5. Do not widen the public contract in the same change that introduces the
   first implementation of a feature.

Mandatory rules:

- no stage starts with exploratory production coding
- no skipped tests for accepted scope
- no stage is considered complete without executable regression coverage
- fixtures used in integration tests are versioned alongside the tests
- the next stage starts only after the current stage exit criteria are green

Test layers used throughout the plan:

- **unit tests** for pure transforms, normalizers, validators, and naming
- **contract tests** for catalog shape, generated GraphQL schema shape, and
  command contracts
- **integration tests** for SQL Server metadata introspection, startup wiring,
  executor behavior, and health behavior
- **snapshot tests** only for stable textual artifacts such as SDL and emitted
  catalog JSON

### Cross-SDK execution cadence

- implementation proceeds in **lockstep by slice**, not as three completely
  independent SDK efforts and not as one fully finished SDK followed by late
  ports
- Dart is the lead SDK for the first slices because it is the team's strongest
  language and best counterweight against Node-specific design bias
- each slice should gain early cross-SDK confidence: the lead SDK goes green
  first, then the same slice is ported promptly to TypeScript and Python before
  advancing to the next slice
- for Stage 1 specifically, TypeScript and Python should gain smoke-level SQL
  Server integration coverage early so cross-SDK viability is checked before
  the full Dart implementation gets too far ahead
- full GraphQL parity across all three SDKs is still a later gate; it should
  begin after a minimal end-to-end vertical exists

---

## 4. Stage Plan

### Stage 1 — Physical Model Introspection

**Goal:** obtain a normalized physical model for published candidate tables and
views from real SQL Server metadata.

**Tests written first:**

- table introspection returns columns, native types, nullability, primary keys,
  and foreign keys
- view introspection returns projected columns, native types, and nullability
- introspection remains stable for the same prepared database state
- physical objects can be normalized into catalog sources even when no
  file-path provenance is available
- unsupported or missing metadata surfaces deterministic diagnostics

**Production scope:**

- SQL Server metadata reader
- normalized `PhysicalObject` / `PhysicalField` / `PhysicalRelationSeed`
  model
- thin driver adapter boundary so metadata queries stay isolated from the
  concrete SQL Server client choice
- fixture database setup for integration tests

**Exit criteria:**

- tables and views can be introspected reproducibly from SQL Server
- the normalized physical model is independent of driver-specific row shapes
- integration tests cover representative table and view fixtures
- before Stage 1 closes, TypeScript and Python have matching smoke integration
  coverage against the same SQL Server fixture set

### Stage 2 — Sidecar Parsing and Governance Validation

**Goal:** parse the JSONC sidecar and validate strict publication rules before
catalog construction.

**Tests written first:**

- only `publish: true` entries are accepted as publication entries
- absent objects are unpublished
- published views require `key`
- published view relations must be explicit
- unknown keys warn and invalid shapes error
- diagnostics are emitted in deterministic canonical order
- sidecar default/object limit ranges reject `default > max`
- references to missing objects fail validation

**Production scope:**

- JSONC parser and metadata schema validator
- governance validation layer
- deterministic diagnostic emission for metadata failures

**Exit criteria:**

- sidecar parsing is independent from runtime wiring
- allowlist and view rules are enforced entirely by tests
- diagnostics are stable enough for snapshot or exact-match assertions

### Stage 3 — Catalog Builder, Naming, and `sourceDigest`

**Goal:** build the governed catalog from the normalized physical model plus
validated sidecar metadata.

**Tests written first:**

- published objects only appear through allowlist entries
- deterministic naming yields expected `typeName`, `itemField`,
  `collectionField`, and `publicName`
- delimiter tokenization is stable for `_`, `-`, `.`, whitespace, and other
  non-alphanumeric separators
- casing tokenization is stable for lower-to-upper and acronym-to-word
  transitions (`idRetiro`, `URLArchivo`, `FechaIDCliente`)
- digits stay attached to adjacent runs during tokenization
- explicit `name` override re-derives item and collection field names
- duplicate derived names emit `duplicate_public_name`
- object-level pagination policy overrides sidecar defaults in the catalog
- missing pagination metadata falls back to v1 defaults (`50` / `200`)
- published tables without valid identity remain collection-only
- published views without identity are rejected before runtime
- published objects, fields, and relations are canonically ordered in the
  catalog output
- semantically ordered arrays such as identity and relation key fields keep
  their declared order
- catalog validity does not depend on `sourceFile`; when present it is preserved
  as optional provenance only
- `sourceDigest` is stable for semantically identical inputs and changes when
  relevant inputs change

**Production scope:**

- catalog builder
- deterministic naming normalizer
- scalar normalization and capability derivation
- canonical ordering and serialization for catalog output and `sourceDigest`

**Exit criteria:**

- catalog objects are reproducible from the same inputs
- naming rules are fully covered by unit tests
- `sourceDigest` is verified with exact-value or golden tests

### Stage 4 — GraphQL Schema Generation Contract

**Goal:** generate the GraphQL schema from the catalog only, with no database
access in the schema generator itself.

**Tests written first:**

- singular field uses `key: <Type>KeyInput!`
- collection field uses `filter`, `orderBy`, and `page`
- collection field returns `<Type>List` with `items` and `totalCount`
- `<Type>KeyInput` uses required public GraphQL field names for every identity
  component, including single-column keys
- filter input includes `and`, `or`, and `not`
- scalar operator inputs match the contract matrix by scalar family
- JSON fields expose no scalar filter operators in v1
- schema omits `notIn`, `between`, regex, full-text, and case-insensitive
  string variants
- order input is `{ field, direction }` and preserves list order as sort
  precedence
- offset pagination shape is shared `OffsetPageInput { limit, offset }` with
  non-negative integers only

**Production scope:**

- SDL/type builder from catalog
- scalar operator input generation
- order enum generation
- list envelope generation

**Exit criteria:**

- SDL snapshot tests are stable and readable
- schema generation depends only on the catalog contract
- no resolver or transport logic leaks into this stage

### Stage 5 — Read Command Compilation and Executor Seam

**Goal:** compile engine-specific read commands without allowing GraphQL to
construct SQL directly.

**Tests written first:**

- item query compiles to `purpose = item`
- collection query compiles to `purpose = collection`
- `totalCount` compiles to `purpose = count`
- relation batching compiles to `purpose = relation-batch`
- `eq: null` and `ne: null` are rejected in favor of `isNull`
- string operators compile according to engine/collation semantics rather than
  GraphQL-defined case-insensitive behavior
- `SqlReadExecutor.execute` receives provider-compiled commands only
- `RowSet` normalization is stable across supported driver adapters

**Production scope:**

- SQL Server read command compiler
- `SqlReadCommand`, `SqlParameter`, `RowSet`, and execution context contract
- executor adapter(s) for the first supported driver path

**Exit criteria:**

- GraphQL runtime never creates SQL strings itself
- the provider owns command compilation
- executor tests prove read-only behavior and normalized results

### Stage 6 — Runtime Integration, Fail-Fast Startup, and Health

**Goal:** integrate the provider, catalog, executor, and schema into the
runtime plugin model.

**Tests written first:**

- GraphQL endpoint mounts under `/{basePath}/graphql`
- startup succeeds when introspection, validation, executor resolution, and
  schema generation all succeed
- startup fails when any of those steps fail and GraphQL is enabled
- core config defaults to `introspection = false`, `maxDepth = 8`, and
  `maxComplexity = 500`
- invalid `maxDepth` or `maxComplexity` configuration fails startup validation
- endpoint authorization failure short-circuits before catalog reads or GraphQL
  execution begin
- health reports `disabled` when GraphQL is not configured
- health reports `ready` when GraphQL is fully initialized

**Production scope:**

- plugin wiring and capability registration
- startup orchestration
- fail-fast initialization gate
- host authorization hook integration
- GraphQL health subsystem exposure

**Exit criteria:**

- runtime integration works end-to-end in an application fixture
- fail-fast behavior is proven by executable integration tests
- health output is deterministic and documented

### Stage 7 — Runtime Hardening and Anti-N+1 Validation

**Goal:** make the runtime viable under realistic query patterns.

**Tests written first:**

- relation resolution uses batched commands rather than one command per parent
- query depth and complexity limits are enforced
- introspection, when explicitly enabled, remains subject to depth and
  complexity limits
- app-level pagination settings narrow catalog limits but never widen them
- omitted `page.limit` uses the effective default limit
- client `page.limit` above the effective max fails validation rather than
  being clamped
- `page.offset` defaults to `0`; negative `limit`/`offset` values are rejected
- `page.limit = 0` yields an empty `items` list while still allowing
  `totalCount`
- `totalCount` is resolved only when selected
- auth and tenant context reach both top-level and relation-batch executor
  calls through request-scoped execution context
- logging or telemetry hooks capture GraphQL lifecycle events

**Production scope:**

- batching/grouping layer above the executor
- limit and complexity enforcement
- lazy count execution
- request and authorization context propagation and instrumentation

**Exit criteria:**

- anti-N+1 behavior is demonstrated against integration fixtures
- runtime limits are covered by contract tests
- observability hooks exist for startup and query execution

### Stage 8 — Compile Mode and Artifact Emission

**Goal:** add build-time emission without changing the runtime-first core.

**Tests written first:**

- compile mode emits `catalog.json`, `catalog.lock`, `diagnostics.json`, and
  `schema.graphql`
- emitted artifacts are byte-stable for identical inputs
- emitted `catalog.json` and `diagnostics.json` are independent of source
  discovery order
- authoritative artifacts omit volatile execution-time data such as generation
  timestamps
- `catalog.lock` includes the expected `sourceDigest`
- runtime fast path loads valid prebuilt artifacts successfully
- drift between normalized inputs and `catalog.lock` is detected

**Production scope:**

- compile entrypoint/CLI
- artifact writer
- runtime fast path for prebuilt artifacts
- drift detection based on `sourceDigest`

**Exit criteria:**

- compile mode reuses the same catalog pipeline as runtime
- artifact snapshots are stable in CI
- runtime can consume emitted artifacts without changing the public contract

---

## 5. Definition of Done

A stage is complete only when all of these are true:

- all acceptance, contract, unit, and integration tests for the stage are green
- no unresolved diagnostics remain for accepted scope
- newly introduced public contract surface is documented in the relevant spec or
  contract file
- regressions discovered during the stage have permanent tests
- the next stage can start without reopening the previous stage's contract

---

## 6. Immediate Execution Order

Implementation should start with shared SQL Server test infrastructure, then
Stage 1, and proceed in order. No product stage should be skipped.

Recommended first execution sequence:

1. Shared Docker-based SQL Server 2019 test infrastructure in `code/infra/docker`
2. Stage 1 — SQL Server physical model introspection, led in Dart with early
  smoke coverage in TypeScript and Python
3. Stage 2 — sidecar parsing and validation
4. Stage 3 — catalog builder, naming, and `sourceDigest`
5. Stage 4 — GraphQL schema generation
6. Stage 5 — read command compiler and executor seam
7. Stage 6 — runtime integration and health
8. Stage 7 — runtime hardening
9. Stage 8 — compile mode and artifacts

This order preserves the runtime-first strategy while ensuring the later
compile-mode work reuses the same tested core and shared infrastructure.