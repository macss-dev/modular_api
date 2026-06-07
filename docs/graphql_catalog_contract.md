# GraphQL Catalog Contract, Sidecar Metadata Format, and Compiler Artifacts

**Status:** Working Draft (formal)
**Date:** 2026-06-02
**Applies to:** GraphQL ecosystem for `modular_api`
**Supersedes the "open syntax" items in:**
[archive/graphql_ecosystem_spec.md](archive/graphql_ecosystem_spec.md),
[archive/graphql_catalog_proposal.md](archive/graphql_catalog_proposal.md)

This document formalizes three things validated against industry practice
(pg_graphql, PostGraphile, Hasura, Microsoft Data API builder):

1. The **minimal catalog schema** as a stable, versioned contract.
2. The **minimal sidecar metadata format** for governed SQL publication.
3. The **compiler artifacts** produced in compile mode and in startup mode.

---

## Part 1 — Minimal Catalog Contract (stable)

### 1.1 Contract principles

- **Versioned.** Every catalog declares `catalogVersion` using semver. Consumers
  reject unknown major versions.
- **Additive evolution.** New optional fields are minor bumps; removing or
  re-typing a field is a major bump.
- **Engine-neutral.** No SQL-Server-specific shapes leak into the catalog; the
  provider normalizes before emission.
- **Deterministic.** Same governed publication inputs + same resolved physical
  shape + same provider version produces a byte-identical catalog (enables
  `sourceDigest` and CI diffing).
- **Self-diagnosing.** Diagnostics are part of the artifact, not only logs.

### 1.2 Scalar type domain (v1)

The catalog uses a closed, engine-neutral scalar set. Providers map native SQL
types into exactly one of these.

```text
CatalogScalar =
  | "Int"        // 32-bit integer
  | "Long"       // 64-bit integer (serialized as string in GraphQL)
  | "Float"      // double precision
  | "Decimal"    // exact numeric (serialized as string)
  | "Boolean"
  | "String"
  | "Date"       // calendar date
  | "DateTime"   // timestamp
  | "Uuid"
  | "Json"       // opaque structured value
```

Unmapped native types are a diagnostic (`unsupported_scalar`), not a silent
fallback.

### 1.3 Catalog schema (normative shape)

Expressed as a typed shape; the wire format is JSON. Field cardinality:
`?` optional, `[]` array.

```text
Catalog
├── catalogVersion: string            // semver of THIS contract
├── provider
│   ├── kind: string                  // e.g. "sql"
│   ├── engine: string                // e.g. "sqlserver" | "postgres"
│   └── providerVersion: string
├── build
│   ├── mode: "compile" | "runtime"
│   ├── sourceRoot: string            // e.g. "db/src"
│   └── sourceDigest: string          // stable hash of normalized inputs
├── objects: PublishedObject[]
└── diagnostics: Diagnostic[]

PublishedObject
├── id: string                        // stable: "<schema>.<object>"
├── kind: "table" | "view"
├── readonly: true                    // invariant in v1
├── source
│   ├── schemaName: string
│   ├── objectName: string
│   ├── sourceFile?: string
│   └── providerObjectId?: string
├── graphql
│   ├── typeName: string              // derived by §1.7 unless overridden
│   ├── collectionField: string       // derived by §1.7 unless overridden
│   └── itemField?: string            // derived by §1.7 when identity exists
├── identity
│   ├── mode: "single" | "composite" | "none"
│   ├── fields: string[]              // source column names
│   └── origin: "inferred" | "annotated"
├── fields: PublishedField[]
├── relations: PublishedRelation[]
└── capabilities: QueryCapabilities

PublishedField
├── column: string                    // source column name
├── publicName: string                // derived by §1.7 unless overridden
├── type: CatalogScalar
├── nullable: boolean
├── visibility: "public" | "hidden"
├── filterable: boolean
├── sortable: boolean
├── sensitive: boolean
└── origin: "inferred" | "annotated"

PublishedRelation
├── name: string                      // derived unless overridden
├── target: string                    // PublishedObject.id
├── cardinality: "one" | "many"
├── sourceFields: string[]
├── targetFields: string[]            // target identity fields in v1
└── origin: "inferred" | "annotated"

QueryCapabilities
├── item: boolean                     // singular lookup by identity
├── collection: boolean
├── filter: boolean
├── sort: boolean
└── pagination
    ├── mode: "offset" | "none"
    ├── defaultLimit: number          // v1 default 50
    └── maxLimit: number              // v1 default 200

Diagnostic
├── severity: "error" | "warning" | "info"
├── code: string                      // stable diagnostic code (see 1.5)
├── message: string
├── objectId?: string
├── field?: string
└── source?: { file: string, line?: number }
```

### 1.4 Catalog invariants (enforced)

1. `readonly` is always `true` in v1.
2. If `identity.mode != "none"`, `graphql.itemField` MUST be present and
  `capabilities.item` MUST be true; otherwise `capabilities.item` MUST be false.
3. `identity.fields` MUST all exist in `fields` with `nullable: false`.
4. Every published object MUST expose `capabilities.collection = true`.
5. Published tables MAY use `identity.mode = "none"`; such objects are
  collection-only in v1.
6. Every published view MUST declare `identity.mode != "none"`; collection-only
  published views are not valid in v1.
7. Every `PublishedRelation.target` MUST resolve to a `PublishedObject.id` in the
   same catalog.
8. `pagination.defaultLimit <= pagination.maxLimit`.
9. A `hidden` field MUST NOT appear in `identity.fields` or in any relation's
   `sourceFields`/`targetFields`.
10. A catalog with any `severity: "error"` diagnostic is **invalid for runtime**
   (compile mode still emits it for inspection).
11. `source.schemaName` and `source.objectName` are required. `source.sourceFile`
  and `source.providerObjectId` are optional provenance hints only.

### 1.5 Stable diagnostic codes (v1 minimum)

```text
view_missing_identity        error   published view without declared identity
identity_field_unknown       error   identity references unknown column
identity_field_nullable      error   identity column is nullable
relation_target_unknown      error   relation target object not published
relation_ambiguous           error   relation cannot be inferred unambiguously
hidden_field_in_key          error   hidden column used as identity/relation key
unsupported_scalar           warning native type not mapped to a CatalogScalar
duplicate_public_name        error   two fields/objects derive the same name
metadata_unknown_key         warning unrecognized metadata key
metadata_invalid_shape       error   metadata file fails schema validation
view_relation_requires_explicit_metadata error published views never infer relations in v1
```

### 1.6 Versioning policy

- The contract version is independent from the `modular_api` product version.
- v1 of this contract is `catalogVersion` `1.x`.
- Providers declare the maximum `catalogVersion` they emit; the catalog plugin
  declares the range it accepts.

### 1.7 Deterministic naming policy (v1)

The public GraphQL surface uses a conservative, deterministic naming policy.

Tokenization rules:

1. Input text is trimmed before tokenization.
2. The following characters are token separators: underscore, hyphen, dot,
  whitespace, and any other non-alphanumeric character.
3. After separator-based splitting, each segment is further split on these
  casing boundaries:
  - lowercase to uppercase transition: `idRetiro` -> `id`, `Retiro`
  - uppercase run followed by a capitalized word:
    `URLArchivo` -> `URL`, `Archivo`
4. Digits stay attached to the current alphanumeric run; digit transitions do
  not create token boundaries by themselves:
  `cliente2Detalle` -> `cliente2`, `Detalle`
5. Acronym tokens are normalized as words during casing:
  `ID` -> `Id`, `URL` -> `Url`

Derived name rules:

6. `graphql.typeName` is derived from `source.objectName` by tokenizing with
  the rules above and joining tokens in `PascalCase`.
7. `graphql.itemField` is derived as `camelCase(typeName)`.
8. `graphql.collectionField` is derived as `camelCase(typeName) + "List"`.
9. `PublishedField.publicName` is derived from `column` using the same
  tokenization rules and `camelCase` output.
10. v1 performs **no automatic singularization, pluralization, or stripping of
   technical prefixes** such as `vw_`, `tbl_`, or similar.
11. Object-level `name` overrides the derived `typeName`; item and collection
   field names are then re-derived from the final `typeName`.
12. Name derivation is pure and repeatable across SDKs; collisions after
   derivation or override emit `duplicate_public_name`.

Normative examples:

- `vw_Retiro` -> `VwRetiro` -> `vwRetiro` -> `vwRetiroList`
- `retiro_evento` -> `RetiroEvento` -> `retiroEvento` -> `retiroEventoList`
- `URL_ARCHIVO` -> `UrlArchivo`
- `FechaIDCliente` -> `FechaIdCliente`
- `cliente2Detalle` -> `Cliente2Detalle`

### 1.8 `sourceDigest` definition (v1)

- `build.sourceDigest` is a SHA-256 hash over UTF-8 encoded canonical JSON.
- The canonical payload contains only semantically relevant inputs:
  - `engine`
  - `providerVersion`
  - relevant provider options affecting catalog output
  - normalized sidecar content with JSONC comments removed
  - normalized physical model for objects participating in the governed catalog
- For SQL Server v1, the physical model component comes from **real engine
  metadata**, not static SQL parsing.
- The canonical payload excludes timestamps, credentials, connection strings,
  machine-local absolute paths, filesystem order, and formatting-only noise.
- Unordered maps or records within the canonical payload are serialized with
  lexicographically sorted keys. Arrays whose order is semantically meaningful
  remain in semantic order.
- Identical normalized inputs MUST produce identical `sourceDigest` values.

### 1.9 Canonical catalog ordering (v1)

For canonical catalog serialization, including emitted `catalog.json`:

1. Object properties MUST be emitted in the order shown by the normative shape
  definitions in Part 1.
2. `Catalog.objects` MUST be sorted by `PublishedObject.id` ascending.
3. `PublishedObject.fields` MUST be sorted by `PublishedField.publicName`
  ascending, with `column` as a tiebreaker.
4. `PublishedObject.relations` MUST be sorted by `PublishedRelation.name`
  ascending, with `target` as a tiebreaker.
5. `Catalog.diagnostics` MUST be sorted by severity (`error`, `warning`,
  `info`), then `code`, then `objectId`, then `field`, then `message`.
6. Arrays whose order is semantically meaningful MUST be preserved as-is. In
  v1 this includes `identity.fields`, `sourceFields`, and `targetFields`.
7. Canonical serialization MUST NOT depend on filesystem traversal order,
  database introspection order, map insertion order, or host-language object
  enumeration behavior.
8. Volatile execution-time data such as generation timestamps MUST NOT appear in
   authoritative canonical artifacts in v1.

Source provenance rules:

1. `source.schemaName` and `source.objectName` are required.
2. `source.sourceFile`, when present, SHOULD be normalized as a relative path
   under the configured source tree or workspace using forward slashes.
3. Absence of `source.sourceFile` MUST NOT invalidate the catalog.
4. `source.providerObjectId`, when present, is provider-defined and
   non-authoritative.

---

## Part 2 — Minimal Sidecar Metadata Format

### 2.1 Design constraints (from prior art)

- One file for the governed SQL tree, easy to validate and diff.
- JSONC-backed structure, so the file stays human-reviewable without turning
  into a bespoke DSL.
- Publication is explicit at object level; absence from the sidecar means the
  object is unpublished.
- Once an object is published, metadata augments inference rather than
  restating the schema.
- Object identities are stable logical ids (`schema.object`), not file paths.
- File-path provenance in the emitted catalog is optional and non-authoritative.
- The same vocabulary could later gain alternative authoring backends, but v1
  standardizes **one** metadata backend only: a sidecar file.

### 2.2 Canonical file

The canonical metadata file for v1 is:

```text
<sourceRoot>/graphql.metadata.jsonc
```

`sourceRoot` is the configured SQL tree root, typically `code/db`.

The file is resolved explicitly from application config or implicitly through
that default convention.

### 2.3 Normative shape

```text
GraphqlMetadataFile
├── $schema?: string
├── version: 1
├── defaults?
│   └── limit?: { default: number, max: number }
└── objects: Record<string, GraphqlObjectMetadata>

GraphqlObjectMetadata
├── publish: true
├── name?: string
├── key?: string[]
├── fields?
│   └── <column>
│       ├── hidden?: boolean
│       ├── sensitive?: boolean
│       ├── noFilter?: boolean
│       ├── noSort?: boolean
│       └── name?: string
├── relations?: MetadataRelation[]
└── limit?: { default: number, max: number }

MetadataRelation
├── name: string
├── cardinality: "to-one" | "to-many"
├── target: string                    // <schema.object>
└── via: string[]
```

In v1, `via` binds the listed source fields to the **identity fields of the
target object** in declared order. Non-identity target field mappings are
deferred; if target identity is missing or arity does not match, validation
fails.

### 2.4 Authoring example

The recommended sidecar form is **one file for the whole SQL tree**, located at
the root of `sourceRoot`, for example:

```text
code/db/graphql.metadata.jsonc
```

JSONC is preferred over strict JSON so the file can carry comments and remain
human-reviewable.

```jsonc
{
  "$schema": "./.modular_api/graphql.metadata.schema.json",
  "version": 1,
  "defaults": {
    "limit": { "default": 50, "max": 200 }
  },
  "objects": {
    "ahorro.vw_Retiro": {
      "publish": true,
      "key": ["idRetiro"],
      "relations": [
        {
          "name": "evento",
          "cardinality": "to-many",
          "target": "ahorro.RetiroEvento",
          "via": ["idRetiro"]
        }
      ]
    },
    "ahorro.RetiroEvento": {
      "publish": true,
      "fields": {
        "codigoError": { "hidden": true },
        "mensajeError": { "sensitive": true, "noSort": true }
      },
      "limit": { "default": 25, "max": 100 }
    }
  }
}
```

Recommended rules for the single-file sidecar:

1. Objects are keyed by stable logical id (`schema.object`), not by file path.
2. File paths may appear only as optional hints for diagnostics, never as the
   primary identity.
3. Publication is strict allowlist: an object appears in the catalog only when
  its sidecar entry declares `publish: true`.
4. Once an object is published, sidecar metadata should stay sparse: it
  augments inference rather than restating every column.
5. The file may contain optional `defaults`; for pagination these define the
  catalog-level fallback policy for published objects. Runtime transport
  settings do not belong here; those remain in application config and may only
  narrow effective behavior.
6. The sidecar governs SQL-backed publication only. It does not replace the app
   plugin configuration object in `code/api`.
7. Object-level `name` overrides `graphql.typeName`; collection and item field
  names are always derived from the final type name.
8. In v1, the sidecar does **not** declare physical field types or nullability
  for published views; the provider obtains that shape from real engine
  metadata.
9. When emitted in the catalog, `source.sourceFile` is optional. If present, it
  is a provenance hint for diagnostics and tooling, not a required identity or
  runtime lookup key.

The full normative shape is defined in §2.3; the example above shows the
recommended sparse authoring form.

### 2.5 Backend policy for v1

For v1, **the sidecar file is the only supported metadata backend**.

In-SQL comment pragmas are intentionally **out of scope for v1**. They may be
revisited in a future version if they deliver enough benefit to justify the
extra authoring surface, parsing rules, and merge complexity.

V1 also standardizes these companion decisions:

- object publication uses a strict allowlist; omission from the sidecar means
  the object is unpublished
- for SQL Server v1, table/view shape comes from real engine metadata; the
  sidecar governs publication and overrides rather than physical typing
- published views MUST declare an explicit `key`
- published view relations MUST be declared explicitly in metadata
- pagination mode is `offset` only; `cursor` is out of scope for v1
- declarative authorization metadata is out of scope for v1
- authorization enforcement remains outside metadata, but the GraphQL runtime
  MUST apply the host API authorization context before executing catalog reads

### 2.5.1 Authorization contract for v1

- endpoint authentication and coarse authorization remain host-owned and must
  run before catalog reads begin
- request-scoped execution context passed into GraphQL must carry the host
  authorization context plus tenant or partition information when applicable
- provider-compiled top-level reads and relation-batch reads must receive that
  same request-scoped execution context
- metadata fields such as `hidden` or `sensitive` may shape the public surface,
  but MUST NOT be treated as authorization policy
- result narrowing may occur through database permissions, curated views,
  and/or executor-scoped filters derived from the host authorization context

### 2.6 Parsing rules

1. The file must parse as JSONC and validate against the metadata schema.
2. Each sidecar object entry is a publication entry; `publish` MUST be `true`.
3. Objects absent from `objects` are unpublished and MUST NOT appear in the
  catalog.
4. Unknown top-level or object-level keys emit `metadata_unknown_key`
  (warning) and are ignored for forward compatibility.
5. Invalid structural shapes emit `metadata_invalid_shape` (error).
6. Object entries are keyed by `schema.object`; duplicate keys after
  normalization are an error.
7. If an object is declared in metadata but cannot be found in the discovered
  SQL model, validation emits an error.
8. Every published view MUST declare `key`; otherwise emit
  `view_missing_identity`.
9. View relations are never inferred in v1; every relation emitted from a
  published view MUST come from explicit metadata.
10. Sidecar field entries may override visibility, filterability, sortability,
  sensitivity, and public naming, but not the physical scalar type or
  nullability of the underlying database field in v1.
11. If `defaults.limit` is present, `defaults.limit.default <= defaults.limit.max`
    MUST hold.
12. If an object-level `limit` is present, `limit.default <= limit.max` MUST
    hold.

### 2.7 Pagination policy resolution (v1)

Catalog pagination policy is resolved per published object using the first
available source in this order:

1. object-level `limit`
2. metadata `defaults.limit`
3. contract defaults: `defaultLimit = 50`, `maxLimit = 200`

This produces `catalogDefaultLimit` and `catalogMaxLimit`, which populate
`QueryCapabilities.pagination.defaultLimit` and
`QueryCapabilities.pagination.maxLimit`. The resolved pair MUST satisfy
`catalogDefaultLimit <= catalogMaxLimit`.

---

## Part 3 — Compiler Artifacts

The same compiler core serves two modes. The difference is what is persisted and
where the catalog lives.

For SQL Server v1, publication intent and governance come from the governed SQL
tree plus sidecar metadata. Physical table/view shape comes from **real engine
metadata** obtained from a prepared database instance.

The first implementation milestone is **runtime-first**. Compile mode remains
part of the contract, but does not block the first runnable delivery.

### 3.1 Compile mode (CI / build)

Inputs: governed publication inputs + provider version. For SQL Server v1, this
means the SQL tree and sidecar metadata in the repository, plus a prepared
database whose metadata can be introspected during build.

Persisted artifacts:

```text
build output (default dir: .modular_api/graphql/)
├── catalog.json            // the full Catalog (Part 1), pretty + canonical order (§1.9)
├── catalog.lock            // { catalogVersion, sourceDigest, providerVersion }
├── diagnostics.json        // Diagnostic[] (also embedded in catalog.json)
└── schema.graphql          // schema preview artifact for inspection
```

Behavior:

- Deterministic output; `catalog.json` uses canonical ordering from §1.9 so CI
  can diff it reliably.
- Exit non-zero if any `error`-severity diagnostic exists.
- `catalog.lock` lets CI detect drift between committed catalog and the
  normalized catalog inputs, including governed publication inputs and resolved
  physical shape (`sourceDigest` mismatch ⇒ fail "catalog out of date").
- `schema.graphql` is always emitted in compile mode for human/PR review.
- CLI is the first-class preview surface in v1; editor preview may consume the
  same emitted artifacts later.
- No source-code generation is required or produced.

Primary use cases: PR review, governance gate, reproducible deploy artifact,
schema-change visibility.

### 3.2 Startup mode (runtime)

Inputs: same governed publication inputs, resolved at process start (or a
prebuilt `catalog.json` if present and `catalog.lock` matches). For SQL Server
v1, startup introspects the real engine metadata for published tables/views
before governance is applied.

Produced artifacts (in-memory unless caching is enabled):

```text
runtime
├── in-memory Catalog          // validated, error-free or startup fails
├── compiled GraphQL schema    // built from the catalog, held in memory
└── optional cache: .modular_api/graphql/catalog.cache.json
```

Behavior:

- If a valid `catalog.json` + matching `catalog.lock` exist, load it directly
  (fast path) instead of re-parsing SQL.
- Otherwise compile in memory from source (dev convenience, PostGraphile
  `--watch` analogue).
- A catalog containing any `error` diagnostic **aborts startup** with a clear,
  aggregated report — the runtime never serves a partially-governed schema.
- The compiled GraphQL schema is shared with the GraphQL plugin via the read
  catalog capability; it is not regenerated per request.

Primary use cases: local development, dynamic environments, low-friction
iteration.

### 3.3 Shared compiler pipeline

Both modes run the same stages; only emission differs.

```text
discover configured source → introspect engine metadata
                          → parse sidecar metadata
                          → normalize names & scalars
                          → infer (keys, relations, capabilities)
                          → apply governance (publication allowlist,
                            field visibility, overrides, limits)
                          → validate (invariants §1.4, diagnostics §1.5)
                          → emit (compile: files | runtime: in-memory +
                            optional cache)
```

### 3.4 Artifact stability guarantees

- `catalog.json` schema is governed by `catalogVersion` (Part 1).
- `catalog.lock` is the contract between CI-built catalogs and runtime loading.
- Authoritative artifacts (`catalog.json`, `catalog.lock`,
  `diagnostics.json`) exclude volatile execution-time values such as
  generation timestamps.
- `schema.graphql` and `catalog.cache.json` are **non-authoritative** and may be
  deleted safely; they are always reproducible from source.

---

## Part 4 — Application Integration Contract (v1 proposal)

This section defines the intended public experience for an application author.
The app should configure **one GraphQL plugin/factory with one configuration
object**. The internal split between provider, catalog, and runtime remains an
implementation detail of the GraphQL ecosystem, not user-facing setup.

### 4.1 Single configuration object

Normative shape:

```text
GraphqlPluginOptions
├── sourceRoot: string
├── metadataFile?: string            // default: <sourceRoot>/graphql.metadata.jsonc
├── compiler
│   ├── mode: "compile" | "runtime"   // first implementation milestone: runtime
│   └── artifactsDir: string
├── execution
│   ├── engine: "sqlserver" | "postgres"
│   ├── capabilityId?: string        // default: modular_api.sql.read_executor
│   └── executor?: SqlReadExecutor
└── graphql
  ├── path: string                  // default "/graphql"
  ├── introspection: boolean        // default false
  ├── paginationMode: "offset" | "none"
  ├── defaultLimit: number
  ├── maxLimit: number
  ├── maxDepth: number              // default 8
  └── maxComplexity: number         // default 500
```

The app author should not configure the provider plugin, catalog plugin, and
runtime plugin separately in the common case.

Validation rules:

1. `execution.executor` and `execution.capabilityId` are mutually exclusive.
2. If `execution.executor` is omitted, `execution.capabilityId` defaults to
  `modular_api.sql.read_executor`.
3. `graphql.paginationMode` defaults to `offset` and `none` is allowed only for
  controlled internal use.
4. `graphql.defaultLimit` and `graphql.maxLimit` MUST be positive integers, and
   `graphql.defaultLimit <= graphql.maxLimit` MUST hold.
5. `graphql.introspection` defaults to `false` in the core contract. The core
  contract does not vary this default by environment.
6. `graphql.maxDepth` defaults to `8` and `graphql.maxComplexity` defaults to
  `500`.
7. `graphql.maxDepth` and `graphql.maxComplexity` MUST be positive integers.
8. Introspection queries, when enabled, remain subject to `graphql.maxDepth`
  and `graphql.maxComplexity` like any other GraphQL operation.

### 4.2 Convention over configuration

If a repository follows a standard layout such as `code/db` for SQL source,
`code/db/graphql.metadata.jsonc` for governance metadata, and
`.modular_api/graphql` for compiler artifacts, a framework-level wrapper MAY
offer a shorthand activation like:

```text
graphql: true
```

That shorthand is only valid when all of these conventions hold:

1. SQL source lives under the default `code/db` tree.
2. Metadata lives in the default sidecar file.
3. Artifacts use the default output directory.
4. Capability `modular_api.sql.read_executor` is available.

If any of those assumptions does not hold, the app must use the explicit object
form. In other words, `graphql: true` is a convenience alias, not the core
contract.

### 4.3 Metadata authoring model

The v1 user workflow is:

1. register one GraphQL plugin in `code/api`
2. edit `graphql.metadata.jsonc` under `code/db`
3. let artifact generation happen automatically according to compiler mode

The system should therefore optimize for **one sidecar metadata file** as the
default governance surface.

### 4.4 Data access decoupling

The GraphQL ecosystem **must not force `modular_api` core to ship or own a
database driver**. The correct seam is an abstract read-execution contract.

Normative runtime abstraction:

```text
SqlReadExecutor
├── execute(command, context) -> RowSet
└── close?() -> void

SqlReadCommand
├── engine: "sqlserver" | "postgres"
├── sql: string
├── parameters: SqlParameter[]
└── purpose: "item" | "collection" | "relation-batch" | "count"

SqlParameter
├── name: string
├── type?: string
└── value: scalar | scalar[] | null

ReadExecutionContext
├── requestId?: string
├── principal?: object
├── tenantId?: string
└── telemetry?: object

RowSet
├── rows: Record<string, scalar | null>[]
└── rowCount: number
```

SqlReadExecutor is a read-only query boundary. It MUST NOT expose write
operations.

GraphQL MUST NOT construct SQL directly. The provider compiles `SqlReadCommand`
instances for the active engine, and the executor only executes those commands.
`ReadExecutionContext` carries request-scoped metadata and stays agnostic of the
hosting HTTP framework and database driver.

The GraphQL plugin obtains this through one of two valid engineering patterns:

1. **Capability injection**: another plugin exposes a read executor through the
  plugin host capability registry, and GraphQL consumes it via
  `requireCapability(...)`.
2. **Direct adapter injection**: the app passes an executor object directly in
  `GraphqlPluginOptions.execution.executor`.

This keeps concerns separated:

- `modular_api` core stays database-agnostic
- the GraphQL engine stays driver-agnostic
- adapter packages may integrate popular drivers without contaminating the core

Batching to avoid N+1 is resolved **above** the executor boundary: the runtime
groups keys, the provider compiles a `relation-batch` command, the executor
executes it once, and the runtime redistributes rows to parent objects.

### 4.5 Reusing existing database access

If the application already owns a SQL pool, connection factory, or read-model
adapter, the preferred approach is to wrap **that existing object** in a
`SqlReadExecutor` adapter rather than opening a second hidden connection path.

However, a separate read-only pool is also valid when the application wants
stronger CQRS isolation, independent scaling, or different credentials for
queries vs commands. The design should permit both. Reuse is preferred by
default; a second read channel is an explicit architectural choice, not a bug.

### 4.6 Automatic artifact handling

Artifact generation should be transparent to the application author.

- In `compile` mode, artifacts are emitted automatically under `artifactsDir`.
- In `runtime` mode, the catalog is compiled in memory and optionally cached.

The app author provides the directory path, but should not manually create or
manage catalog files as part of normal usage.

### 4.7 Generated GraphQL query surface (v1)

Normative shapes:

```text
Query root
├── <itemField>(key: <TypeName>KeyInput!): <TypeName>
└── <collectionField>(
      filter?: <TypeName>FilterInput
      orderBy?: [<TypeName>OrderByInput!]
      page?: OffsetPageInput
    ): <TypeName>List!

<TypeName>List
├── items: [<TypeName>!]!
└── totalCount: Int!

<TypeName>KeyInput
├── <identityPublicField1>: <GraphqlScalar>!
└── ... one required field per identity component

<TypeName>OrderByInput
├── field: <TypeName>OrderField!
└── direction: SortDirection!

<TypeName>OrderField
└── one enum value per published field with `sortable: true`

SortDirection
├── ASC
└── DESC

OffsetPageInput
├── limit?: Int
└── offset?: Int
```

Rules:

1. Singular lookup always uses a single `key` argument, even for simple keys.
2. `<TypeName>KeyInput` contains one required field per identity component.
  Field names come from the corresponding `PublishedField.publicName`, not
  from raw SQL column names.
3. Composite and single-column identities use the same object-shaped `key`
  contract; v1 defines no scalar shortcut for single-column keys.
4. Collection queries return a formal envelope type, not a bare list.
5. `totalCount` is part of the contract and MAY be computed lazily when the
  selection set requests it.
6. Filters are typed per field, using shared scalar operator inputs plus
  logical combinators `and`, `or`, and `not`.
7. `<TypeName>FilterInput` exposes only published fields with
   `filterable: true`.
8. `Int`, `Long`, `Float`, `Decimal`, `Date`, and `DateTime` use these scalar
   operators in v1: `eq`, `ne`, `in`, `lt`, `lte`, `gt`, `gte`, `isNull`.
9. `String` uses these scalar operators in v1: `eq`, `ne`, `in`, `contains`,
   `startsWith`, `endsWith`, `isNull`.
10. `Boolean` uses `eq`, `ne`, `isNull`. `Uuid` uses `eq`, `ne`, `in`,
   `isNull`.
11. `Json` exposes no scalar filter operators in v1.
12. String comparison semantics follow the underlying database engine and its
    collation. v1 defines no case-insensitive variants, regex operators,
    full-text operators, `notIn`, `between`, or JSON-path filters.
13. `isNull` is the only null-test operator in v1. `eq: null` and `ne: null`
    are invalid.
14. `<TypeName>OrderByInput.field` uses a generated enum derived from
   `PublishedField.publicName` for fields with `sortable: true`.
15. `orderBy` is an ordered list of precedence clauses; the first element is
   the primary sort, the second element is the secondary sort, and so on.
16. Pagination uses shared `OffsetPageInput` with `limit` and `offset` only.
17. `OffsetPageInput.limit` and `OffsetPageInput.offset` are optional,
   non-negative integers.
18. For each published object, catalog pagination limits resolve in this order:
  object-level `limit`, then metadata `defaults.limit`, then contract
  defaults (`50` and `200`).
19. Application-level `graphql.defaultLimit` and `graphql.maxLimit` are
  operational guardrails layered on top of the catalog policy; they MAY
  narrow effective behavior but MUST NOT widen it.
20. `effectiveMaxLimit = min(catalogMaxLimit, graphql.maxLimit)`.
21. `effectiveDefaultLimit = min(catalogDefaultLimit, graphql.defaultLimit,
  effectiveMaxLimit)`.
22. If `page` is omitted or `page.limit` is omitted, the runtime uses
  `effectiveDefaultLimit`.
23. If `page.limit` is provided, it MUST satisfy
  `0 <= page.limit <= effectiveMaxLimit`; otherwise request validation fails.
24. The runtime MUST NOT silently clamp a client-supplied `page.limit`.
25. If `page.offset` is omitted, the runtime uses `0`. If `page.offset` is
  provided, it MUST be `>= 0`.
26. `page.limit = 0` is valid and returns an empty `items` list; `totalCount`
  remains available when selected.

### 4.8 Runtime startup and health behavior (v1)

If GraphQL is enabled, startup succeeds only when all of these complete
successfully:

1. engine metadata introspection
2. sidecar validation
3. catalog construction
4. executor resolution
5. schema construction

Any failure aborts application startup. v1 does not serve a degraded GraphQL
surface.

The shared health surface exposes GraphQL as a subsystem with these minimum
states:

- `disabled`: GraphQL is not configured for the application
- `ready`: the catalog is valid, the executor is resolved, the schema is built,
  and the endpoint is mounted

---

## Part 5 — V1 Closure

The following decisions are now closed for v1:

- catalog schema, invariants, scalar domain, diagnostic codes (Part 1)
- sidecar metadata format (Part 2)
- compile-mode and startup-mode artifacts (Part 3)
- application integration contract and data-access seam (Part 4)
- publication uses a strict object-level allowlist
- first implementation milestone is runtime-first
- SQL Server v1 obtains table/view shape from real engine metadata
- naming is deterministic and conservative; overrides are explicit
- `sourceDigest` is canonical SHA-256 over normalized semantic inputs
- query surface uses `key`, `filter`, `orderBy`, `page`, and collection
  envelopes with `items` and `totalCount`
- GraphQL never constructs SQL; providers compile read commands for executors
- startup is fail-fast when GraphQL is enabled, and health exposes GraphQL as a
  subsystem
- published views require explicit identity metadata
- published view relations are explicit-only
- pagination is offset-only
- schema preview is CLI-first via emitted `schema.graphql`
- declarative authorization metadata is out of scope

There are no remaining design blockers for a v1 provider/runtime implementation.
Future extensions remain possible, but they are not prerequisites for v1.
