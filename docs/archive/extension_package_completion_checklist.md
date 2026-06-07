# Extension Package Completion Checklist

**Status:** Working checklist
**Date:** 2026-06-05
**Applies to:** `modular_api`, `service_client`, and SQL engine package delivery

---

## 1. Architecture And Contract Freeze

- [ ] Confirm [architecture.md](architecture.md) remains the canonical server-core specification.
- [ ] Confirm [application_boundary_architecture_spec.md](application_boundary_architecture_spec.md) as the canonical layer-separation document.
- [ ] Confirm [service_client_model_spec.md](service_client_model_spec.md) as the canonical outbound-client model.
- [ ] Confirm [db_client_model_spec.md](db_client_model_spec.md) as the canonical database-client model.
- [ ] Confirm [twelve_package_development_spec.md](twelve_package_development_spec.md) as the canonical package-map and delivery-order document.
- [ ] Confirm the v1 one-shot helper names are frozen as `httpClient()` and `graphqlClient()` across SDKs.
- [ ] Confirm GraphQL client v1 uses raw operation strings as the normative document input.
- [ ] Confirm the frozen Postgres driver set: Dart `postgres`, TypeScript `pg`, Python `psycopg`.
- [ ] Confirm TypeScript and Python extension packages stay workspace-local until conformance, CI, and API freeze are green.

---

## 2. `modular_api` Core Completion

- [ ] Keep the base `modular_api` package free of concrete SQL Server and Postgres drivers.
- [ ] Keep GraphQL-base free of concrete SQL Server and Postgres drivers.
- [ ] Confirm plugin-host boundaries remain stable for health, metrics, OpenAPI, docs, and GraphQL.
- [ ] Confirm `UseCase` remains the business entry point and no server-side controller layer is introduced.
- [ ] Confirm server-side outbound integrations go through services backed by `service_client`, not raw HTTP.
- [ ] Confirm persistence goes through repositories backed by `db_client`, not raw drivers.
- [ ] Keep examples green in Dart, TypeScript, and Python.

---

## 3. Package Skeletons For The 12 New Roots

- [ ] Add a real manifest to every package root under `code/dart`, `code/ts`, and `code/py`.
- [ ] Add a README to every package root.
- [ ] Add a CHANGELOG to every package root.
- [ ] Add a minimal source entry point to every package root.
- [ ] Add at least one smoke test to every package root.
- [ ] Ensure every package root can build from its own directory.

---

## 4. `modular_api_rest_client` Family

- [ ] Define `ServiceClientConfig` in an idiomatic way for Dart, TypeScript, and Python.
- [ ] Define the normalized operation descriptor and response model.
- [ ] Define `ServiceResult<T>` and `ServiceFailure` consistently across SDKs.
- [ ] Implement a long-lived REST client facade.
- [ ] Implement the exact one-shot helper `httpClient()` in every SDK.
- [ ] Support headers, auth, timeout, and retry policy.
- [ ] Provide test doubles or fake transport support.
- [ ] Add cross-SDK conformance fixtures for request/response semantics.

---

## 5. `modular_api_graphql_client` Family

- [ ] Keep the GraphQL client query-only in v1.
- [ ] Reuse the lower-level transport grammar of `modular_api_rest_client`.
- [ ] Define `GraphqlRequest`, `GraphqlResponse<T>`, and normalized GraphQL failures.
- [ ] Use raw operation strings as the normative v1 GraphQL document input.
- [ ] Preserve transport failures separately from GraphQL `errors` payloads.
- [ ] Avoid a mandatory heavy GraphQL client dependency in v1.
- [ ] Implement the exact one-shot helper `graphqlClient()` in every SDK.
- [ ] Add smoke tests against a real `/graphql` endpoint shape.
- [ ] Add cross-SDK conformance fixtures for `{ data, errors, extensions }`.

---

## 6. `modular_api_sqlserver` Family

- [ ] Move SQL Server driver ownership completely out of base `modular_api`.
- [ ] Implement the package against [db_client_model_spec.md](db_client_model_spec.md).
- [ ] Implement connection settings, session or pool provider, command execution, and transaction helpers.
- [ ] Implement normalized SQL Server failures.
- [ ] Implement repository helpers without becoming a generic ORM.
- [ ] Implement health contribution and startup validation support.
- [ ] Implement GraphQL metadata and read integration on the same package.
- [ ] Add clean-room tests proving the base package does not require the SQL Server driver.

---

## 7. `modular_api_postgres` Family

- [ ] Use the frozen Postgres driver set: Dart `postgres`, TypeScript `pg`, Python `psycopg`.
- [ ] Keep the same package shape already proven by `modular_api_sqlserver`.
- [ ] Implement connection settings, session or pool provider, command execution, and transaction helpers.
- [ ] Implement normalized Postgres failures.
- [ ] Implement repository helpers without creating a second divergent architecture.
- [ ] Implement health contribution and startup validation support.
- [ ] Implement GraphQL metadata and read integration on the same package.
- [ ] Add clean-room tests proving the base package does not require the Postgres driver.

---

## 8. Cross-SDK Engineering Quality

- [ ] Every package family has unit tests.
- [ ] Every package family has smoke tests.
- [ ] Every package family has regression tests.
- [ ] Every package family has at least one conformance-oriented cross-SDK suite.
- [ ] Every package family has package-root build validation in CI.
- [ ] Base `modular_api` install/import remains green with no database driver present.
- [ ] GraphQL-base install/import remains green with no database driver present.

---

## 9. Documentation And Examples

- [ ] Document installation and usage for every new package.
- [ ] Document the canonical layer flow: `view -> controller -> application service -> service_client -> local api -> use case -> repository -> db_client -> db`.
- [ ] Document the server-side external flow: `local api -> use case -> server-side service -> service_client -> external api`.
- [ ] Add example apps or fixtures showing local API consumption through REST and GraphQL clients.
- [ ] Add example apps or fixtures showing repository plus engine-package usage.

---

## 10. Release And Adoption

- [ ] Keep TypeScript and Python extension packages workspace-local until conformance, CI, and API freeze are green.
- [ ] Add versioning rules for the new package family.
- [ ] Update release automation for new package roots.
- [ ] Add downstream acceptance coverage for the MACSS CLI where relevant.
- [ ] Record future transport decisions such as gRPC through ADRs or spec updates.