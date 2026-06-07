# Release Validation Matrix

Status date: 2026-06-06
Scope: 12 complementary packages (REST client, GraphQL client, SQL Server, Postgres across Dart/TypeScript/Python)

## Workflows Coverage

Implemented workflows for complementary package publish:

- Dart
  - .github/workflows/publish-dart-rest-client.yml
  - .github/workflows/publish-dart-graphql-client.yml
  - .github/workflows/publish-dart-sqlserver.yml
  - .github/workflows/publish-dart-postgres.yml
- TypeScript
  - .github/workflows/publish-ts-rest-client.yml
  - .github/workflows/publish-ts-graphql-client.yml
  - .github/workflows/publish-ts-sqlserver.yml
  - .github/workflows/publish-ts-postgres.yml
- Python
  - .github/workflows/publish-py-rest-client.yml
  - .github/workflows/publish-py-graphql-client.yml
  - .github/workflows/publish-py-sqlserver.yml
  - .github/workflows/publish-py-postgres.yml

## Local Validation Matrix

Legend:
- PASS: validated in this session with command output observed
- PARTIAL: validation started but needs deterministic rerun in clean shell
- BLOCKED: deterministic run blocked by shell-session command interleaving

| Package | Validation Target | Status | Evidence |
|---|---|---|---|
| dart/modular_api_rest_client | dart pub get + analyze + test | PASS | tests passed (7) and analyze clean |
| dart/modular_api_graphql_client | dart pub get + analyze + test | PASS | tests passed (7) and analyze clean |
| dart/modular_api_sqlserver | dart pub get + analyze + targeted test | PASS | targeted db_client_test passed |
| dart/modular_api_postgres | dart pub get + analyze + test | PASS | package tests passed |
| ts/modular_api_rest_client | npm ci + test + build | PARTIAL | run started in shared shell; needs clean rerun |
| ts/modular_api_graphql_client | npm ci + test + build | PASS | vitest passed (7), build executed |
| ts/modular_api_sqlserver | npm ci + test + build | PARTIAL | run started in shared shell; needs clean rerun |
| ts/modular_api_postgres | npm ci + test + build | PASS | vitest passed (14), build executed |
| py/modular_api_rest_client | pip editable install + pytest | PARTIAL | install observed; pytest invocation needs clean rerun with python -m pytest |
| py/modular_api_graphql_client | pip editable install + pytest | PARTIAL | install observed; pytest invocation needs clean rerun with python -m pytest |
| py/modular_api_sqlserver | pip editable install + pytest | PARTIAL | install observed; pytest invocation needs clean rerun with python -m pytest |
| py/modular_api_postgres | pip editable install + pytest | PARTIAL | install observed; pytest invocation needs clean rerun with python -m pytest |

## Publish Readiness Observations

- TypeScript publish workflows enforce package publishability (`private` must be false).
- Current package metadata currently blocks publish for:
  - code/ts/modular_api_graphql_client/package.json (`private: true`)
  - code/ts/modular_api_sqlserver/package.json (`private: true`)
  - code/ts/modular_api_postgres/package.json (`private: true`)
- Current package metadata currently blocks pub.dev publish for:
  - code/dart/modular_api_graphql_client/pubspec.yaml (`publish_to: none`)
  - code/dart/modular_api_postgres/pubspec.yaml (`publish_to: none`)

These are intentional safety checks in workflows; publish will fail until metadata is switched to publishable values.
