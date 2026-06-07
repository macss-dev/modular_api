# Twelve Package Development Specification

**Status:** Proposed
**Date:** 2026-06-04
**Applies to:** 12 new extension packages across Dart, TypeScript, and Python

---

## 1. Purpose

This document defines the development specification for the 12 new packages
introduced by the new snake_case package-root layout.

The goal is to make the next implementation phase explicit before code is
written.

This specification freezes:

- the package matrix
- the dependency direction between packages
- the responsibility boundaries of each package family
- the cross-SDK development order
- the minimum acceptance criteria required before a package is considered done

This document does not replace the existing contract and architecture
documents.

It complements:

- [service_client_model_spec.md](service_client_model_spec.md)
- [db_client_model_spec.md](db_client_model_spec.md)
- [application_boundary_architecture_spec.md](application_boundary_architecture_spec.md)

This document remains the package-map and delivery-order specification for the
full 12-package extension set.

---

## 2. Scope

This specification covers the 12 new extension packages only.

It does not redefine the existing `modular_api` core package in each SDK.
`modular_api` is treated as an existing prerequisite and remains outside the
count of 12.

The 12 packages are:

- 3 `service_client_rest` packages, one per SDK
- 3 `service_client_graphql` packages, one per SDK
- 3 `modular_api_sqlserver` packages, one per SDK
- 3 `modular_api_postgres` packages, one per SDK

---

## 3. Package Matrix

### 3.1 Workspace roots

The workspace roots are fixed and use snake_case in every SDK.

| SDK | REST client | GraphQL client | SQL Server engine | Postgres engine |
| --- | --- | --- | --- | --- |
| Dart | `code/dart/modular_api_rest_client` | `code/dart/modular_api_graphql_client` | `code/dart/modular_api_sqlserver` | `code/dart/modular_api_postgres` |
| TypeScript | `code/ts/modular_api_rest_client` | `code/ts/modular_api_graphql_client` | `code/ts/modular_api_sqlserver` | `code/ts/modular_api_postgres` |
| Python | `code/py/modular_api_rest_client` | `code/py/modular_api_graphql_client` | `code/py/modular_api_sqlserver` | `code/py/modular_api_postgres` |

### 3.2 Published package names

Workspace roots stay snake_case. Published names follow registry conventions.

| SDK | REST client | GraphQL client | SQL Server engine | Postgres engine |
| --- | --- | --- | --- | --- |
| Dart | `modular_api_rest_client` | `modular_api_graphql_client` | `modular_api_sqlserver` | `modular_api_postgres` |
| TypeScript | `@macss/modular-api-rest-client` | `@macss/modular-api-graphql-client` | `@macss/modular-api-sqlserver` | `@macss/modular-api-postgres` |
| Python | `macss-modular-api-rest-client` | `macss-modular-api-graphql-client` | `macss-modular-api-sqlserver` | `macss-modular-api-postgres` |

---

## 4. Product Model

The intended ecosystem shape is:

- `modular_api` = server-side core HTTP plus GraphQL-base contracts/runtime-
  neutral seams used by the future optional GraphQL plugin
- `modular_api_rest_client` = client/service-to-service REST transport package
- `modular_api_graphql_client` = client-side GraphQL query package
- `modular_api_sqlserver` = SQL Server engine integration package for
  `modular_api`
- `modular_api_postgres` = Postgres engine integration package for
  `modular_api`

This means the platform has two extension families:

- `service_client_*` family for outbound calls
- `db_client_*` family, published here as `modular_api_<engine>`, for inbound
  server-side database integration

In this document, `service_client` and `db_client` are architectural family
names. The concrete published package names for this phase are the
`modular_api_*` packages listed above.

The current phase deliberately does not introduce a 13th shared package such as
`service_client_core` or `db_client_core`. Shared behavior may be implemented
internally within each package until duplication becomes large enough to justify
another artifact.

---

## 5. Dependency Rules

### 5.1 Global rules

Dependency direction must remain simple and acyclic.

Allowed:

- application -> `modular_api`
- application -> `modular_api_rest_client`
- application -> `modular_api_graphql_client`
- application -> `modular_api_sqlserver`
- application -> `modular_api_postgres`
- `modular_api_sqlserver` -> `modular_api`
- `modular_api_postgres` -> `modular_api`
- `modular_api_graphql_client` -> `modular_api_rest_client`

Rejected:

- `modular_api` -> any extension package
- `modular_api_rest_client` -> `modular_api`
- `modular_api_graphql_client` -> `modular_api`
- `modular_api_sqlserver` -> `modular_api_postgres`
- `modular_api_postgres` -> `modular_api_sqlserver`
- service-client packages -> database packages
- database packages -> service-client packages

### 5.2 Why GraphQL client may depend on REST client

The 12-package constraint means this phase will not introduce a separate shared
HTTP transport package.

Therefore, `modular_api_graphql_client` may depend on
`modular_api_rest_client`, but only for these protocol-neutral capabilities:

- HTTP transport lifecycle
- request execution
- auth/header injection
- retry/timeout policy
- one-shot transport helpers
- testing fakes or spies

`modular_api_graphql_client` must not depend on REST-resource semantics,
OpenAPI-specific helpers, or code generation concerns.

This dependency is an implementation convenience, not a second public contract.
`modular_api_graphql_client` must still expose the shared `service_client`
grammar defined in [service_client_model_spec.md](service_client_model_spec.md).

### 5.3 Database driver rule

The external database driver always belongs to the engine package, never to the
base `modular_api` package.

This rule is mandatory in all SDKs and especially critical in Dart.

Where the SDK supports it, driver dependencies should be declared as optional,
peer, or extras-style dependencies with permissive ranges rather than as hard
required pins.

---

## 6. Family Specification

## 6.1 `modular_api_rest_client`

### Purpose

Provide the official MACSS outbound HTTP transport for REST calls.

This package serves two scenarios:

- client applications calling a MACSS API
- server applications calling third-party HTTP services

### Responsibilities

- own the persistent HTTP client abstraction
- provide a one-shot convenience API equivalent to `httpClient()`
- model requests, responses, headers, query params, and JSON payloads
- support auth/header injection, timeout policy, and retry policy
- support request/response interception where the SDK idiom makes sense
- provide a fake or spy transport for tests

### Non-goals

- OpenAPI code generation in v1
- multipart upload specialization in v1
- WebSocket, SSE, or gRPC transport
- GraphQL request semantics
- domain-specific API client generation

### Minimum public model

Conceptual surface:

```text
ServiceClientConfig
ServiceOperation or ServiceRequest
ServiceResponse
ServiceResult<T>
ServiceFailure
ServiceClient
HttpServiceClient
httpClient(...) one-shot helper
```

`ServiceRequest` is an ergonomic REST-specialized request shape layered over the
shared `ServiceOperation` contract.

Required behavior:

- send HTTP methods `GET`, `POST`, `PUT`, `PATCH`, `DELETE`
- encode query params predictably
- send JSON request bodies
- parse status, headers, raw body, and JSON body
- fail clearly on timeout, transport failure, and invalid JSON

---

## 6.2 `modular_api_graphql_client`

### Purpose

Provide the official MACSS outbound GraphQL query client.

This package exists for read-side GraphQL consumption only.

### Responsibilities

- send GraphQL operations over HTTP POST
- accept `query`, `variables`, and optional `operationName`
- parse `{ data, errors, extensions }` responses
- expose GraphQL failures distinctly from transport failures
- reuse the low-level HTTP transport behavior of
  `modular_api_rest_client`
- provide a fake or spy GraphQL transport for tests

### Non-goals

- subscriptions in v1
- local normalized cache in v1
- GraphQL schema code generation in v1
- mandatory dependency on heavy GraphQL client frameworks
- GraphQL mutations in v1; commands remain REST use cases

### Minimum public model

Conceptual surface:

```text
ServiceClientConfig
ServiceOperation or GraphqlRequest
GraphqlRequest
GraphqlResponse<T>
GraphqlError
ServiceResult<T>
ServiceFailure
GraphqlClient
graphqlClient(...) one-shot helper
```

`GraphqlRequest` is a transport-specialized request shape layered over the
shared `ServiceOperation` contract.

Required behavior:

- execute query operations successfully against `/graphql`
- carry request headers and auth from the underlying transport
- preserve server-provided GraphQL errors
- separate protocol errors from transport errors
- allow raw-string operation documents in v1
- remain query-only in v1; GraphQL mutations stay out of scope and commands
  remain REST use cases

---

## 6.3 `modular_api_sqlserver`

### Purpose

Provide the official SQL Server integration package for `modular_api`.

### Normative reference

This package must satisfy [db_client_model_spec.md](db_client_model_spec.md).

### Responsibilities

- own SQL Server connection settings
- own SQL Server session or pool provider behavior
- own SQL Server execution and transaction helpers
- own normalized SQL Server failures
- own SQL Server repository helpers
- own SQL Server health contribution
- own GraphQL metadata/read support for SQL Server
- own the concrete SQL Server driver dependency and lazy loading strategy when
  the SDK supports it

### Non-goals

- becoming a generic ORM
- forcing SQL Server driver dependencies into `modular_api`
- hiding SQL Server so aggressively that escape hatches disappear

---

## 6.4 `modular_api_postgres`

### Purpose

Provide the official Postgres integration package for `modular_api`.

### Normative reference

This package must satisfy [db_client_model_spec.md](db_client_model_spec.md).

### Responsibilities

- own Postgres connection settings
- own Postgres session or pool provider behavior
- own Postgres execution and transaction helpers
- own normalized Postgres failures
- own Postgres repository helpers
- own Postgres health contribution
- own GraphQL metadata/read support for Postgres
- own the concrete Postgres driver dependency and lazy loading strategy when
  the SDK supports it

### Non-goals

- becoming a generic ORM
- forcing Postgres driver dependencies into `modular_api`
- introducing a second divergent repository model separate from SQL Server

---

## 7. Cross-SDK Conformance Rules

Every package family must expose equivalent behavior across Dart, TypeScript,
and Python.

Language idioms may differ, but the public contract must remain aligned.

### 7.1 Conformance artifacts

The development effort must create shared conformance fixtures for:

- REST request and response behavior
- GraphQL envelope behavior (`data`, `errors`, `extensions`)
- database failure normalization semantics
- engine metadata and GraphQL-read behavior where relevant

### 7.2 Required test categories

Each package must have:

- unit tests for local behavior
- smoke tests for public happy paths
- regression tests for previous bugs
- one conformance-oriented suite proving the package family behaves the same in
  all SDKs

---

## 8. Development Order

The packages must be developed family-first, not by trying to build all 12 in
parallel.

### Stage 0. Freeze specs and create package skeletons

- confirm this document
- keep package roots as already created
- add minimal manifests, README placeholders, and test placeholders in all 12
  roots
- do not implement runtime logic yet

### Stage 1. Implement `modular_api_rest_client` in Dart

Rationale:

- Dart is already central in the adjacent MACSS client usage vocabulary
- the persistent-client plus one-shot-helper shape is easy to prove here first

### Stage 2. Port `modular_api_rest_client` to TypeScript and Python

- add cross-SDK conformance tests
- freeze the REST client surface before GraphQL depends on it

### Stage 3. Implement `modular_api_graphql_client` in Dart

- build on the REST client transport model
- query-only behavior is mandatory in v1

### Stage 4. Port `modular_api_graphql_client` to TypeScript and Python

- keep the GraphQL client lightweight
- confirm the same GraphQL error model across SDKs

### Stage 5. Implement `modular_api_sqlserver` in Dart

- this remains the first engine path to prove the db-client model
- move all SQL Server driver ownership out of base `modular_api`

### Stage 6. Port `modular_api_sqlserver` to TypeScript and Python

- align on the same engine semantics and normalized failures
- keep driver ownership local to the engine package in each SDK

### Stage 7. Implement `modular_api_postgres` in Dart

- reuse the already-proven db-client model
- do not invent a new architecture for Postgres

### Stage 8. Port `modular_api_postgres` to TypeScript and Python

- keep parity with the SQL Server package shape
- only engine-specific concerns should differ

---

## 9. Definition Of Done

A package is done only when all of the following are true.

- it has its own manifest and publish metadata
- it builds and tests green from its own package root
- it has a README with purpose, install, and minimal example
- it has at least one smoke test for the public happy path
- it has regression coverage for its key failure modes
- it passes the conformance checks for its package family
- it does not violate the dependency rules in Section 5
- it does not introduce forbidden eager database-driver imports into
  `modular_api`

---

## 10. Immediate Next Deliverables

The next concrete deliverables after approving this spec are:

1. create minimal manifests and README placeholders for the 12 package roots
2. align package skeletons and public contracts with
  [service_client_model_spec.md](service_client_model_spec.md) and
  [application_boundary_architecture_spec.md](application_boundary_architecture_spec.md)
3. add package-root smoke tests that prove each package can build in isolation
4. start Stage 1 with the Dart `modular_api_rest_client`

---

## 11. Closed V1 Decisions

The following decisions are now frozen for v1.

- one-shot helper names are exactly `httpClient()` and `graphqlClient()` in
  all SDKs; only the hosting form differs by language idiom
- `modular_api_graphql_client` accepts raw operation strings as the normative
  document input in v1; shipped AST or document-wrapper contracts are out of
  scope
- TypeScript and Python extension packages ship workspace-local first in v1;
  public publication starts only after package-root CI, conformance coverage,
  and API freeze are green

Postgres driver choices are also frozen for v1.

| SDK | Driver |
| --- | --- |
| Dart | `postgres` |
| TypeScript | `pg` |
| Python | `psycopg` |

Any change to these decisions requires an explicit spec update or ADR before
implementations diverge.