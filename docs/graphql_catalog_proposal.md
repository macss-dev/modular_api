# GraphQL Public Read Catalog Proposal

**Status:** Working Draft
**Date:** 2026-06-02
**Applies to:** GraphQL ecosystem design for `modular_api`

> This is the conceptual proposal. The formal, versioned contract derived from
> it lives in [graphql_catalog_contract.md](graphql_catalog_contract.md).
> For v1, governance metadata is standardized as one sidecar file for the SQL
> tree; inline SQL comment pragmas are deferred.

---

## 1. Purpose

This document proposes the intermediate catalog that sits between governed SQL
publication inputs and the final GraphQL schema.

Its purpose is to define a stable conceptual model for publication,
authorization, inference, diagnostics, and runtime execution without forcing
the system to treat the physical SQL schema and the public GraphQL contract as
the same thing.

In SQL Server v1, publication intent and governance come from the SQL tree plus
sidecar metadata, while physical shape comes from real engine metadata.

---

## 2. Position in the Pipeline

```mermaid
flowchart LR
  A[SQL tree in db/] --> D[Governance metadata application]
  B[graphql.metadata.jsonc] --> D
  C[Real engine metadata] --> E[Physical SQL model]
  D --> F[SQL provider compiler]
  E --> F
  F --> G[Public read catalog]
  G --> H[GraphQL schema construction]
  H --> I[/{basePath}/graphql runtime]
```

The catalog is the canonical public read model for the GraphQL ecosystem.

---

## 3. Design Goals

1. Preserve the governed SQL tree as the primary input for publication intent
  and governance.
2. Avoid hand-written duplication of table names, column names, and relations.
3. Keep governance explicit and reviewable.
4. Be engine-agnostic even if providers are engine-specific.
5. Be rich enough to support GraphQL schema construction automatically.
6. Be rich enough to support editor tooling and diagnostics.
7. Support both compile-time and startup-time construction.

These goals are validated by industry practice: pg_graphql and PostGraphile
both derive schema from SQL with sparse, colocated overrides for published
entities rather than a second handwritten schema. See the prior-art review in
[graphql_ecosystem_spec.md](graphql_ecosystem_spec.md#4-prior-art-and-industry-references).

---

## 4. Top-Level Catalog Shape

### 4.1 Catalog Metadata

- `catalogVersion`
- `providerKind`
- `engine`
- `sourceRoot`
- `buildMode` (`compile` or `runtime`)
- `sourceDigest`

### 4.2 Published Objects

Each published object represents one SQL table or one SQL view in v1, carrying:
source reference, object kind, read mode, identity, field set, relation set,
query capabilities, and authorization/governance metadata.

In v1, the catalog uses a strict allowlist: an object appears only when it is
published explicitly through sidecar metadata. Absence from the sidecar means
the object is not part of the public GraphQL surface.

### 4.3 Diagnostics

The catalog can carry or reference structured diagnostics produced by the
compiler (published view without identity, relation inference conflict,
unsupported construct, metadata rule referencing unknown field).

---

## 5. Published Object Model

### 5.1 Source Reference

Every published object keeps a strong trace back to SQL source (`schemaName`,
`objectName`, `objectKind`, optional `sourceFile`, optional
`providerObjectId`). The public model derives from this logical reference
instead of asking the developer to rewrite names. `sourceFile` is provenance,
not identity, and may be absent when the provider cannot map the object back to
one concrete SQL file.

### 5.2 Public Name Derivation

Deterministic derivation, not hand-written renaming. SQL names are the source of
truth; GraphQL-facing names are normalized by conservative compiler rules.
`PascalCase` is used for type names, `camelCase` for fields, and collection
fields use a stable `List` suffix rather than language-aware pluralization.
Tokenization is separator- and casing-based: `_`, `-`, `.`, whitespace, and
other non-alphanumeric characters split tokens; lowercase-to-uppercase and
acronym-to-word transitions split segments further; acronym runs normalize as
ordinary words (`URLArchivo` -> `UrlArchivo`). Aliasing is optional and
exceptional.

### 5.3 Identity

Identity rules are intentionally asymmetric in v1. Tables infer identity from
primary keys when present; a published table without a valid identity is exposed
as collection-only and offers no singular lookup. Views require explicit
identity annotation (the same rule pg_graphql enforces with
`primary_key_columns` and PostGraphile with `@primaryKey`), and a published view
without identity is invalid in v1 rather than collection-only.

---

## 6. Field Model

Per field: source column name, public field name (derived), scalar type,
nullability, read visibility, filterability, sortability, sensitivity
classification, and which inferred/explicit annotations were applied.

### 6.1 Default Philosophy

Compiler-first. Object publication is explicit, but once an object is
published, fields are derived from provider metadata by default. Metadata only
overrides governance-relevant behavior (hide, disallow filter, disallow sort,
mark sensitive). It is never necessary to restate every column manually.

---

## 7. Relationship Model

Per relationship: id, source object, target object, cardinality, join
definition, inferred vs explicit, visibility/governance flags.

- **Tables**: infer relationships from foreign keys where possible.
- **Views**: allow explicit annotations to declare target object, source/target
  fields, and cardinality. This is the clearest case where explicit metadata is
  justified (PostGraphile virtual `@foreignKey` exists for exactly this).

---

## 8. Query Capability Model

Per object: singular lookup by identity, collection query, field filters,
ordering, pagination. Runtime behavior is built from the catalog instead of
re-deriving policy ad hoc. In v1, singular lookup uses a uniform `key` input,
collection queries use typed `filter`, `orderBy`, and `page` inputs, and
collections return a formal envelope with `items` and `totalCount`.

`<TypeName>KeyInput` is always object-shaped, even for single-column keys, and
uses public GraphQL field names rather than SQL column names. `orderBy` is an
ordered list of `{ field, direction }` clauses, where `field` is chosen from a
generated enum of sortable public fields. `OffsetPageInput` is shared and
contains only `limit` and `offset`.

The v1 filter surface is intentionally conservative. Numeric and comparable
scalars use `eq`, `ne`, `in`, `lt`, `lte`, `gt`, `gte`, `isNull`; strings use
`eq`, `ne`, `in`, `contains`, `startsWith`, `endsWith`, `isNull`; booleans use
`eq`, `ne`, `isNull`; UUIDs use `eq`, `ne`, `in`, `isNull`; JSON fields are
not scalar-filterable in v1. String comparison semantics follow the database
engine and collation rather than defining GraphQL-specific case-insensitive
variants.

Pagination policy is also layered deliberately. The catalog resolves each
object's policy from object-level metadata, then sidecar defaults, then the v1
contract defaults. Application config may narrow those limits globally for
operations, but never widen them. Over-limit requests fail validation rather
than being silently clamped.

---

## 9. Authorization and Governance Model

The catalog carries object visibility, field visibility, relation visibility,
and sensitivity metadata. Declarative authorization metadata is out of scope
for v1. Authorization remains a distinct enforced layer outside the catalog —
hiding a field is surface shaping, not security.

---

## 10. Inference Rules for v1

- **Tables**: infer columns, scalar types, nullability, primary keys,
  foreign-key relations.
- **Views**: for SQL Server v1, obtain projected columns, scalar types, and
  nullability from real engine metadata; require explicit metadata for identity
  and for every published relation. v1 does not infer relations for views.

---

## 11. What the Catalog Should Not Become

It must not become a second handwritten schema language. It must not require
rewriting all object names, all column names, the full relation graph, or
duplicating the SQL schema in another DSL just to publish it. If that happens,
the design has failed the low-duplication goal.

---

## 12. Conceptual Example

```json
{
  "catalogVersion": "1.0.0",
  "engine": "sqlserver",
  "buildMode": "runtime",
  "objects": [
    {
      "id": "ahorro.vw_Retiro",
      "kind": "view",
      "graphql": {
        "typeName": "VwRetiro",
        "collectionField": "vwRetiroList",
        "itemField": "vwRetiro"
      },
      "source": {
        "schemaName": "ahorro",
        "objectName": "vw_Retiro",
        "sourceFile": "db/src/modules/ahorro/Views/vw_Retiro.sql"
      },
      "readonly": true,
      "identity": { "mode": "single", "fields": ["idRetiro"], "origin": "annotated" },
      "fields": [
        { "column": "idRetiro", "publicName": "idRetiro", "type": "Int", "nullable": false, "visibility": "public", "filterable": true, "sortable": true, "sensitive": false, "origin": "inferred" },
        { "column": "dni", "publicName": "dni", "type": "String", "nullable": false, "visibility": "public", "filterable": true, "sortable": false, "sensitive": false, "origin": "inferred" }
      ],
      "relations": [],
      "capabilities": {
        "item": true,
        "collection": true,
        "filter": true,
        "sort": true,
        "pagination": { "mode": "offset", "defaultLimit": 50, "maxLimit": 200 }
      }
    }
  ]
}
```

The point is the conceptual contract: enough information to build GraphQL
automatically while staying anchored to governed SQL source.

The example includes `sourceFile` because that trace is often useful in
tooling, but the formal contract allows it to be absent.

---

## 13. Tooling Implications

A stable intermediate catalog enables compiler diagnostics, VS Code linting for
publication metadata, CI validation of governed SQL publication, runtime loading
of prebuilt catalog artifacts, and CLI-first schema preview without source-code
generation. The first executable milestone is runtime-first; compile artifacts
reuse the same provider/catalog pipeline later. Those artifacts should be
canonically serialized: derived collections are sorted by stable semantic keys,
while arrays whose order carries meaning remain in semantic order. That keeps
`catalog.json`, `diagnostics.json`, and digest inputs byte-stable across SDKs
and future compile/runtime paths. Volatile execution-time data such as
generation timestamps should stay outside the authoritative catalog artifacts.

The runtime contract should also keep security defaults explicit and portable:
introspection off by default, positive mandatory depth/complexity limits in the
core contract, and any development-friendly preset handled outside the base
contract.

---

## 14. Immediate Next Step

The conceptual model above is now formalized as a versioned contract, a sidecar
metadata format, and a compiler artifact specification in
[graphql_catalog_contract.md](graphql_catalog_contract.md). The staged rollout
plan is defined in [graphql_v1_tdd_plan.md](graphql_v1_tdd_plan.md).
