# GraphQL Ecosystem Specification

**Status:** Working Draft
**Date:** 2026-06-02
**Applies to:** Dart, TypeScript, Python, and future SDKs

---

## 1. Purpose

This document defines the emerging architecture for the GraphQL ecosystem in
`modular_api`.

The scope is broader than a single runtime plugin. The intended capability
requires a full toolchain that starts from governed SQL source, constructs a
public read catalog, and exposes that catalog through a read-only GraphQL
surface mounted inside the existing API runtime.

This is a product and architecture specification. It is not yet the final
runtime API for plugin authors. The formal contract is defined in
[graphql_catalog_contract.md](graphql_catalog_contract.md).

---

## 2. Settled Direction

The following points are considered aligned for the current design phase.

1. The governed SQL tree plus its sidecar metadata are the source of truth for
  publication intent and governance.
2. Governance must live in one sidecar metadata file located in or very near
  the SQL source tree.
3. The GraphQL schema must be constructed automatically from the governed
  catalog built from those inputs.
4. The endpoint must be `/{basePath}/graphql`.
5. The endpoint must run through the same request pipeline, logging, middleware,
   and authorization model as the rest of the API.
6. The model is read-only.
7. SQL is a provider of read models; GraphQL is the public query surface.
8. The system must support both compile-time construction and startup-time
   construction.
9. The design must not depend on hand-written GraphQL DTOs or resolvers for the
   standard case.
10. The design must not require the developer to re-declare table names,
    column names, or relationships manually just to make the system work.
11. The first implementation milestone is runtime-first; compile mode remains a
  planned follow-on using the same provider/catalog pipeline.
12. For SQL Server v1, table/view shape is obtained from real engine metadata;
  the sidecar governs publication and overrides rather than physical typing,
  and file-path provenance in the catalog is optional.
13. Public naming is deterministic and conservative; overrides are explicit.

---

## 3. Architectural Thesis

The intended architecture is:

```text
SQL physical model -> governed public read catalog -> GraphQL schema
```

This deliberately separates three concepts that must not be collapsed into one:

1. The physical SQL model.
2. The governed public read catalog.
3. The client-facing GraphQL schema.

The public GraphQL contract may be derived automatically from SQL, but it must
still pass through a governed intermediate model so that publication,
authorization, visibility, relation semantics, and diagnostics remain explicit
and reviewable. Collapsing these layers would make every internal database
refactor a public API change.

In SQL Server v1, the logical source of truth remains the governed SQL tree plus
sidecar metadata, while physical table/view shape is materialized from real
engine metadata. File-path provenance is useful for tooling, but not required
for catalog validity.

---

## 4. Prior Art and Industry References

The design was reviewed against established read-from-SQL GraphQL/REST systems.
The convergence is strong: the chosen direction is mainstream, not speculative.

### 4.1 Supabase `pg_graphql`

- Configuration is expressed as **comment directives** attached to SQL entities,
  using the literal form `@graphql({<JSON>})` on `comment on table/view/column`.
- **Views require an explicit identity**: a view must declare
  `primary_key_columns` before it can be queried by identity. This is exactly
  the "views need explicit identity" rule in this spec.
- Pagination is governed: `max_rows` caps page size per schema/table/view, with
  fallback to the parent scope.
- **Introspection is disabled by default** in production to reduce API
  enumeration. Security-by-default is a baked-in posture, not an add-on.
- Naming is derived by default (`inflect_names` maps `snake_case` to
  `PascalCase`/`camelCase`); explicit renaming is optional and exceptional.
- Opt-in extras (`totalCount`, `aggregate`) are declared per entity.

Reference: <https://supabase.github.io/pg_graphql/configuration/>

### 4.2 PostGraphile Smart Tags

- The original mechanism is **smart comments** (`comment on ... is '@tag ...'`),
  with an alternate sidecar file (`postgraphile.tags.json5`) carrying the same
  tags. Two backends, one tag vocabulary.
- Tag values are intentionally a **small grammar**: `true`, a string, or an
  array of strings.
- Views are made "table-like" through **virtual constraints**: `@primaryKey`,
  `@foreignKey (cols) references schema.table (cols)`, `@unique`, `@notNull`.
- Field/operation governance: `@omit`, `@filterable`, `@sortable`,
  `@deprecated`, `@name`.
- Explicit warning: `@omit` **is not a permission system**; it removes things
  from the API surface and must be backed by real database permissions. This
  separation of "surface shaping" from "authorization" is a key lesson.

Reference: <https://postgraphile.org/postgraphile/4/smart-tags/>

### 4.3 Hasura

- Uses an explicit **tracking / allowlist** model: an object exists in the
  database but is invisible to the API until it is tracked. Publication is
  opt-in, never implicit.
- Permissions (row/column) are a **separate layer** from schema tracking.
- Views are first-class read sources, including the canonical pattern of
  publishing a curated view to hide sensitive columns.
- Custom business logic that needs input belongs in SQL functions, not views.

Reference: <https://hasura.io/docs/2.0/schema/postgres/views/>

### 4.4 Microsoft Data API builder (DAB)

- Closest reference for the SQL Server target: a config-driven engine that
  exposes SQL Server / Azure SQL tables, views, and procedures as REST **and**
  GraphQL.
- Views and procedures require explicit **key-fields** and declared
  relationships, mirroring this spec's view-identity and relation rules.
- Per-entity permissions and policy expressions are part of the entity
  definition, reinforcing governance-as-configuration.

Reference: <https://learn.microsoft.com/azure/data-api-builder/>

### 4.5 Takeaways Adopted Into This Design

1. Industry practice validates both comment-based and sidecar-based governance
  as viable patterns.
2. A tiny, typed tag grammar beats a free-form DSL. Keep values to
   `true | string | string[] | small JSON`.
3. Views must carry explicit identity and explicit relations. Do not pretend
   they can always be inferred.
4. Introspection off by default and bounded pagination are security defaults,
   not options.
5. **Surface shaping (`omit`, `hidden`) is not authorization.** Authorization
   must be a distinct, enforced layer, never implied by hiding a field.
6. For `modular_api` v1, standardize on one canonical backend rather than two:
  a single sidecar metadata file for the SQL tree.

---

## 5. Quality Review of the Current Direction

A critical pass against the references surfaced the following.

### 5.1 Strengths

- The three-layer separation (physical / catalog / schema) is more disciplined
  than pg_graphql's direct DB-to-schema mapping and gives a real governance
  seam.
- Read-only + "commands stay REST" is a clean CQRS boundary that none of the
  references contradict.
- Compile-time + startup-time duality matches PostGraphile's `--watch` vs
  precompiled split and DAB's config-build model.

### 5.2 Risks and Required Mitigations

1. **N+1 / relation traversal.** GraphQL over relational data is the canonical
   N+1 trap. The runtime plugin must use batched/dataloader-style resolution
   from day one; this is now an explicit runtime requirement (see §8).
2. **Query cost.** Depth, breadth, and complexity limits must exist before any
   public exposure. pg_graphql/Hasura both cap page size by default.
3. **Authorization vs visibility conflation.** Hiding a field must never be
  treated as securing it. The v1 contract keeps authorization outside sidecar
  metadata and outside the catalog surface, echoing the PostGraphile lesson that
  surface shaping is not a permission system.
4. **SQL Server view metadata is thin.** Inference for views will be limited;
  v1 therefore relies on real engine metadata for view shape, while explicit
  sidecar metadata remains mandatory for identity and relations.
5. **Metadata robustness.** Free-form extraction across many SQL files is
  brittle. The sidecar must be schema-validatable and diagnosable, which the
  contract now formalizes.

---

## 6. Ecosystem Components

The GraphQL capability is delivered as an ecosystem of cooperating components
rather than a monolithic plugin.

### 6.1 Pure GraphQL Plugin

- mount `/{basePath}/graphql`
- own GraphQL transport behavior
- execute queries against a public read catalog
- share request context, logging, middleware, and auth with the existing API
- apply runtime query limits such as depth, breadth, or cost limits
- batch relation resolution to avoid N+1 access patterns

### 6.2 Read Catalog Plugin

- own the intermediate public read catalog
- expose the catalog as a capability to the GraphQL plugin
- provide a stable contract between source providers and GraphQL runtime
- emit and consume canonically ordered catalog artifacts so identical governed
  inputs stay byte-stable across SDKs and environments
- keep volatile execution-time data outside authoritative catalog artifacts
- remain engine-agnostic

### 6.3 SQL Provider Plugin Per Engine

- read SQL source from the `db/` tree
- understand engine-specific schema constructs
- obtain physical table/view shape from real engine metadata
- apply governance metadata near the SQL source
- produce the public read catalog consumed by the catalog layer

The first provider targets SQL Server. The ecosystem treats SQL as a class of
providers (PostgreSQL next), not a hardcoded implementation.

### 6.4 Compiler / Interpreter Toolchain

- parse or analyze SQL source plus governance metadata
- build a physical model
- build the governed public read catalog
- report diagnostics and policy violations
- optionally emit reusable artifacts for CI or deployment

The first implementation milestone is runtime-first. Compile mode reuses the
same provider/catalog pipeline once build-time database introspection is added.

### 6.5 Development Tooling

- CLI/compiler installable in development and CI
- VS Code diagnostics/linting for sidecar metadata
- artifact validation commands
- optional language server support over time

### 6.6 Application Integration Surface

Application authors should see one GraphQL activation surface, not three
separate internal components. The provider, catalog, and runtime layers remain
architectural internals behind a single plugin/factory configuration object.

When a repository follows a conventional layout such as `code/db` for SQL
source, the ecosystem may offer convention-over-configuration shortcuts. Those
shortcuts must remain aliases over an explicit configuration contract, not the
only supported path.

Under the v1 convention, governance metadata lives in
`code/db/graphql.metadata.jsonc` unless the app explicitly overrides that path.

### 6.7 Read Execution Capability

The GraphQL ecosystem must stay decoupled from concrete database drivers.

- `modular_api` core must not ship SQL Server or PostgreSQL driver logic
- GraphQL runtime must depend on an abstract read-query executor contract
- providers compile read commands; GraphQL runtime does not build SQL directly
- the executor may be supplied via plugin-host capability injection or direct
  adapter injection from application code
- reusing an existing read pool is preferred, but a dedicated read-only pool is
  also valid and aligns with CQRS separation

---

## 7. Read Model Scope

### 7.1 v1 Scope

In: tables, views. Out: mutations, write paths, side effects, stored procedures
as public GraphQL read sources. Read flows that still depend on procedure
semantics remain REST use cases.

### 7.2 Query vs Command Language

- GraphQL = queries
- REST use-case endpoints = commands

This preserves the optional CQRS profile already reflected in the roadmap.

---

## 8. Runtime Contract Expectations

- mounted under the shared `basePath`
- participates in the same middleware pipeline
- receives the same request-scoped logging semantics
- relies on the same plugin host capability model
- requires no core-only escape hatches
- uses a conservative typed filter surface by scalar family rather than a
  free-form query DSL
- enforces depth/breadth/cost limits and bounded pagination by default
- treats app-level pagination settings as operational guardrails that can
  narrow, but not widen, catalog policy
- disables introspection by default in the core contract
- uses explicit core defaults for runtime limits (`maxDepth = 8`,
  `maxComplexity = 500`) rather than environment-sensitive behavior
- resolves relations through batched access to avoid N+1
- fails startup if GraphQL is enabled but introspection, validation, executor
  resolution, or schema construction fail
- reports GraphQL through the shared health surface

---

## 9. Governance Model

1. publication is explicit and opt-in (allowlist posture, as in Hasura tracking)
2. absence from the sidecar means unpublished; v1 does not define a publish-all
  mode
3. publication metadata lives in one sidecar file in or near the SQL source
  tree
4. the compiler enforces governance as part of the build/runtime flow
5. authorization is enforced outside sidecar metadata through API auth,
  database permissions, curated views, and/or executor-scoped filters
6. **field hiding is surface shaping, not authorization**

Governance metadata must be additive and low-duplication for published objects:
it augments inference rather than restating the schema.

For v1, string filter behavior follows engine semantics and collation; the
contract does not introduce GraphQL-specific case-insensitive operators.
For pagination, client requests above the effective limit are rejected rather
than silently clamped.
Security defaults belong to the core contract, not to environment detection.
Framework wrappers may offer development presets, but the base contract stays
explicit and stable.

---

## 10. Inference Policy

### 10.1 Tables

Prefer automatic inference for columns, scalar types, nullability, primary keys,
and foreign-key relationships. In v1, a published table without a valid
identity may still be exposed as collection-only.

### 10.2 Views

For SQL Server v1, obtain columns, types, and nullability from real engine
metadata. Views still require explicit metadata for object identity and every
published relation. Published views without identity are invalid in v1, and v1
does not infer relations for views.

---

## 11. Build Modes

- **Compile-time construction**: CI validation, deterministic artifacts,
  reviewable PR output, preflight governance enforcement.
- **Startup-time construction**: local development, low-friction iteration.

The same compiler model serves both, but the first implementation milestone is
runtime-first. Source-code generation is not a required product model. Concrete
artifacts are defined in
[graphql_catalog_contract.md](graphql_catalog_contract.md).

---

## 12. Relation to Existing modular_api Contracts

1. GraphQL remains optional.
2. REST-only APIs remain valid.
3. GraphQL must mount under `/{basePath}`.
4. GraphQL must use the same plugin host and request pipeline.
5. GraphQL must not require core-only escape hatches.

The GraphQL ecosystem is an extension of the existing plugin host, not a
parallel subsystem.

---

## 13. Non-Goals for This Phase

- mutation support
- stored procedure publication in v1
- engine-specific optimization details
- transport protocols beyond GraphQL over HTTP for this feature

(Final sidecar metadata format, artifact format, and compiler CLI UX are no
longer open non-goals; they are formalized in the contract document.)

---

## 14. V1 Closure

The following v1 decisions are now closed:

1. Declarative authorization metadata is out of scope.
2. Publication uses a strict object-level allowlist.
3. The first implementation milestone is runtime-first.
4. SQL Server v1 obtains table/view shape from real engine metadata.
5. Public naming is deterministic and conservative.
6. Published views require explicit identity metadata.
7. Published view relations are explicit-only; no automatic view relation
  inference exists in v1.
8. Schema preview is CLI-first through emitted compile artifacts.
9. Pagination is offset-only in v1.

---

## 15. Immediate Next Step

The catalog contract, sidecar metadata format, and compiler artifacts are now
formalized in [graphql_catalog_contract.md](graphql_catalog_contract.md). The
staged rollout is formalized in [graphql_v1_tdd_plan.md](graphql_v1_tdd_plan.md).
The next implementation step is Stage 1 of that plan: a SQL Server provider
prototype that materializes a normalized physical model from real engine
metadata.
