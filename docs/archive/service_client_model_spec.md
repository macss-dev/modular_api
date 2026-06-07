# Service Client Model Specification

**Status:** Proposed
**Date:** 2026-06-05
**Applies to:** Cross-SDK outbound service consumption model for Dart, TypeScript, and Python

---

## 1. Purpose

This document defines one transport-agnostic specification for the
`service_client` model used by the MACSS ecosystem.

The purpose of this model is to standardize how applications, CLIs, and
backends consume local or external APIs through a coherent outbound-client
boundary instead of scattering raw HTTP or transport code across controllers,
views, services, or use cases.

The model is designed so that:

- a client application can call a local MACSS API through one consistent
  service-client contract
- a server-side use case can call an external API through the same conceptual
  client model
- REST and GraphQL can feel like one family of outbound clients instead of two
  unrelated libraries
- future transports such as gRPC can be added without changing the architectural
  role of the client boundary
- outbound failures, results, observability, and lifecycle management stay
  standardized across SDKs

This specification is intentionally independent from any one protocol library,
HTTP framework, or SDK language.

---

## 2. Naming Scope

This document specifies the **model** name `service_client`.

It does **not** freeze the final published branding of the packages. Possible
published names include:

- `service_client_rest`, `service_client_graphql`
- `modular_api_rest_client`, `modular_api_graphql_client`
- `macss-rest-client`, `macss-graphql-client`

For the rest of this specification, the neutral model names are:

- `service_client_rest`
- `service_client_graphql`
- future `service_client_grpc`

---

## 3. Product Model

The intended product shape is:

- `modular_api` = local server-side API core
- `service_client_rest` = official outbound REST transport package
- `service_client_graphql` = official outbound GraphQL query package
- future `service_client_grpc` = official outbound gRPC transport package

The same conceptual model supports two runtime scenarios.

### 3.1 Local API consumption

An application, CLI, or another backend may call its own local MACSS API
through a `service_client` package instead of importing server-side use cases or
repositories directly.

### 3.2 External API consumption

A server-side use case may call an external API through a domain service that is
backed by a `service_client` package instead of using raw transport primitives.

Dependency direction must always be:

- application -> chosen `service_client_*` package(s)
- application -> `modular_api` only when it also hosts the local API
- server-side service -> chosen `service_client_*` package(s)

Dependency direction must never be:

- `modular_api` -> `service_client_*`

The server core must not own the outbound-client packages.

---

## 4. Design Goals

The `service_client` model has these goals.

- Provide one coherent outbound-client family across SDKs.
- Keep raw transport libraries out of controllers, views, and use cases.
- Standardize result and failure semantics for outbound calls.
- Support both long-lived clients and one-shot convenience helpers.
- Support local API consumption and external API consumption through the same
  conceptual model.
- Make GraphQL consumption feel like an extension of the same client family,
  not an unrelated stack.
- Leave room for future gRPC without changing the architecture.

---

## 5. Non-Goals

The `service_client` model is not intended to become:

- an API-specific code generator in v1
- a frontend state-management or caching framework
- a full SDK generator for every remote API
- a replacement for application services or controllers
- a transport abstraction so generic that it erases the meaning of REST,
  GraphQL, or future gRPC

The service client is an architectural boundary and product surface, not a full
integration platform.

---

## 6. Core Principles

### 6.1 Service package, not raw transport, is the product surface

Applications should depend on a service-client package, not on raw `fetch`,
`http`, `requests`, `dio`, `axios`, or transport primitives scattered through
the codebase.

### 6.2 The service client is transport-aware but domain-agnostic

The client family must understand transport concerns such as HTTP methods,
headers, GraphQL envelopes, retries, and timeouts, but it must not embed
business-specific service logic.

### 6.3 Application services own remote intent

Domain-specific services such as `CustomerService`, `BillingService`, or
`PaymentGatewayService` should depend on `service_client`, but the generic
client package must not try to become those services.

### 6.4 Results and failures must be normalized

Outbound transport code must return structured results and failures instead of
leaking arbitrary transport-library exceptions through the application.

### 6.5 Lifecycle ownership must be explicit

If the application provides a long-lived underlying client or transport handle,
the service-client package must reuse it and must not silently create a second
hidden one.

### 6.6 Future transports should preserve the same grammar

REST, GraphQL, and future gRPC do not need identical syntax, but they should
present the same conceptual grammar:

- config
- operation descriptor
- normalized result
- normalized failure
- long-lived client
- one-shot helper
- explicit close or shutdown lifecycle when applicable

---

## 7. Model Layers

Each `service_client_<transport>` package is built from five conceptual layers.

### 7.1 Configuration layer

Defines base URL, auth strategy, default headers, timeout policy, retry policy,
and telemetry hooks.

### 7.2 Execution layer

Owns request execution, response receipt, cancellation or timeout behavior, and
resource lifecycle.

### 7.3 Mapping layer

Owns serialization and deserialization of request and response payloads.

### 7.4 Failure normalization layer

Owns the translation from raw transport-library exceptions into stable
`ServiceFailure` values.

### 7.5 Transport specialization layer

Owns protocol-specific rules such as:

- HTTP method/path/query rules for REST
- `query`/`variables`/`errors` rules for GraphQL
- future RPC or streaming rules for gRPC

---

## 8. Core Abstract Contracts

The following contracts are transport-agnostic. Each concrete package may layer
transport-specific request types over them.

### 8.1 Client configuration

`ServiceClientConfig`

Responsibilities:

- capture outbound transport configuration
- normalize defaults for auth, timeout, retries, and headers
- support safe redaction for logs and diagnostics

Required properties:

- `serviceId`
- `baseUrl`
- `redactedSummary`

Optional properties:

- `defaultHeaders`
- `authProvider`
- `timeout`
- `retryPolicy`
- `userAgent`
- `telemetryHooks`

### 8.2 Operation descriptor

`ServiceOperation`

Responsibilities:

- describe one outbound call in a transport-neutral way
- give the client enough metadata for retries, logging, and diagnostics
- keep protocol-specific payload details explicit rather than implicit

Required fields:

- `transportId`
- `operationId`
- `headers`

Transport-specific optional fields:

- `method`
- `path`
- `query`
- `body`
- `document`
- `variables`
- `operationName`
- future RPC fields for gRPC

`service_client_rest` and `service_client_graphql` may expose higher-level
request types that map cleanly onto this conceptual contract.

### 8.3 Normalized response

`ServiceResponse<T>`

Responsibilities:

- carry the decoded payload
- preserve transport metadata needed by the caller
- keep headers and status available for advanced use cases

Required fields:

- `data`
- `metadata`

Recommended metadata fields:

- `statusCode`
- `headers`
- `transportId`
- `duration`
- `requestId`

### 8.4 Result container

`ServiceResult<T>`

`ServiceResult` is the canonical success or failure container for outbound
service consumption.

Rules:

- all direct service-client execution operations return `ServiceResult<T>`
- the success branch contains the normalized response payload
- the failure branch contains `ServiceFailure`
- applications may bridge `ServiceResult<T>` into exceptions if they prefer,
  but the package must expose the normalized result form first

### 8.5 Failure model

`ServiceFailure`

Responsibilities:

- normalize transport and protocol failures
- preserve retryability and category information
- support redacted diagnostics without leaking secrets

Required fields:

- `category`
- `code`
- `message`
- `retryable`

Recommended optional fields:

- `statusCode`
- `transportId`
- `details`
- `causeSummary`

Suggested categories:

- `transport`
- `timeout`
- `auth`
- `rate_limit`
- `protocol`
- `decode`
- `graphql`
- `unexpected`

### 8.6 Long-lived client

`ServiceClient`

Responsibilities:

- execute outbound operations
- manage or reuse a transport lifecycle
- expose close or shutdown semantics when the underlying runtime requires them

Conceptual contract:

```text
execute<T>(operation, decoder?) -> ServiceResult<ServiceResponse<T>>
close() -> ServiceResult<void>
describe() -> ServiceClientDescription
```

### 8.7 One-shot helper

For v1, official packages MUST expose exact one-shot helper names for callers
that do not need a persistent client.

- `httpClient(...)` for REST
- `graphqlClient(...)` for GraphQL

These names are frozen across SDKs. Only the hosting form differs by language
idiom:

- Dart: top-level function
- TypeScript: exported function
- Python: module-level function

Future transport helper naming, such as `grpcClient(...)`, remains out of scope
for v1.

These helpers are sugar over the long-lived client surface. They must preserve
the same result and failure semantics.

---

## 9. Result Pattern Rules

The Result pattern is part of the `service_client` model.

Rules:

- all direct outbound operations return `ServiceResult<T>`
- all failures are structured through `ServiceFailure`, not arbitrary transport
  exceptions
- one-shot helpers return the same normalized result model
- bridge helpers may convert `ServiceResult<T>` into application exceptions when
  the app chooses that style

The Result pattern is meant to standardize outbound service flow, not to force
the entire MACSS ecosystem to abandon every exception-based API.

---

## 10. Transport Rules

### 10.1 REST rules

The REST client package must:

- support `GET`, `POST`, `PUT`, `PATCH`, and `DELETE`
- treat path, query, headers, and body as explicit parts of the operation
- support JSON payloads first in v1
- preserve HTTP status and headers in the normalized response

### 10.2 GraphQL rules

The GraphQL client package must:

- send operations through HTTP POST in v1
- accept `document`, `variables`, and optional `operationName`
- use raw operation strings as the normative v1 document contract
- preserve GraphQL `errors` distinctly from transport failures
- remain query-oriented in v1
- build on the same transport grammar used by the REST client family

Shipped AST or document-wrapper contracts are out of scope for v1.

### 10.3 Future gRPC rule

If `service_client_grpc` is introduced later, it must preserve the same
high-level grammar:

- client config
- operation descriptor
- normalized result
- normalized failure
- long-lived client
- one-shot helper when applicable

---

## 11. Operational Integration Rules

Each service-client package should provide measured operational integration.

Required capabilities:

- timeout support
- request correlation or request ID propagation hooks
- redacted diagnostics
- resource close or shutdown support when applicable

Recommended capabilities:

- retry policy with explicit opt-in semantics
- structured logging hooks
- tracing hooks
- metrics hooks

Retries must never be implicit for unsafe or non-idempotent operations unless
the caller explicitly opted in.

---

## 12. Public API Coherence With `db_client`

The `service_client` and `db_client` families do not expose identical types, but
they should expose the same public grammar.

| Concern | `service_client` | `db_client` | Coherence rule |
| --- | --- | --- | --- |
| Config | `ServiceClientConfig` | `DbConnectionSettings` | explicit config object, never hidden globals |
| Operation | `ServiceOperation` | `DbCommand` | explicit operation descriptor, never positional call soup |
| Success/failure container | `ServiceResult<T>` | `DbResult<T>` | tagged result model first |
| Failure | `ServiceFailure` | `DbFailure` | normalized failure taxonomy |
| Long-lived facade | `ServiceClient` | `DbClient` or engine root facade | caller can reuse lifecycle explicitly |
| One-shot helper | `httpClient()` / `graphqlClient()` | engine helper or execution shortcut | sugar must preserve the same semantics |
| Lifecycle | `close()` | `close()` / `release()` | no hidden resource ownership |

This rule exists so application code sees one coherent engineering style even
when the transport boundary and the persistence boundary are different.

---

## 13. SDK Mapping

The model is shared across SDKs, but each language should expose it in an
idiomatic way.

| Concept | Dart | TypeScript | Python |
| --- | --- | --- | --- |
| Async result | `Future<ServiceResult<T>>` | `Promise<ServiceResult<T>>` | `Awaitable[ServiceResult[T]]` |
| Result type | sealed class | discriminated union | tagged dataclass or typed union |
| Shared contracts | abstract class / interface | interface / abstract class | Protocol / ABC |
| Long-lived client | class with async methods | interface plus concrete class | protocol plus concrete class |
| One-shot helper | top-level function | exported function | module-level function |

The semantic contract should match even when syntax differs.

---

## 14. Package Responsibilities

### 14.1 `service_client_rest`

Must provide:

- REST client configuration
- REST operation builder or request type
- HTTP execution path
- normalized `ServiceResult<T>` and `ServiceFailure`
- one-shot helper for REST usage
- test doubles or fake transport support

### 14.2 `service_client_graphql`

Must provide:

- GraphQL client configuration additions when needed
- GraphQL operation or request type
- GraphQL envelope parsing
- normalized `ServiceResult<T>` and `ServiceFailure`
- one-shot helper for GraphQL query execution when useful
- reuse of the lower-level HTTP transport grammar from the REST client family

### 14.3 Future `service_client_grpc`

If introduced later, it must provide the same grammar and remain architecture-
compatible with the rest of the family.

---

## 15. Immediate Build Order

The recommended build order is:

1. define the abstract `service_client` model and tests
2. implement `service_client_rest` in Dart first
3. port `service_client_rest` to TypeScript and Python
4. implement `service_client_graphql` on top of the proven transport grammar
5. port `service_client_graphql` to TypeScript and Python
6. reserve the model shape for future `service_client_grpc`

This sequence keeps the transport family coherent before adding more protocols.