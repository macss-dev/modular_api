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

| Package | Validation Target | Status | Evidence |
|---|---|---|---|
| dart/modular_api_rest_client | dart pub get + analyze + test | PASS | tests passed (7) and analyze clean |
| dart/modular_api_graphql_client | dart pub get + analyze + test | PASS | tests passed (7) and analyze clean (using local `pubspec_overrides.yaml` for dependency bootstrap) |
| dart/modular_api_sqlserver | dart pub get + analyze + targeted test | PASS | targeted db_client_test passed |
| dart/modular_api_postgres | dart pub get + analyze + test | PASS | package tests passed |
| ts/modular_api_rest_client | npm ci + test + build | PASS | vitest passed (7), build executed |
| ts/modular_api_graphql_client | npm ci + test + build | PASS | vitest passed (7), build executed |
| ts/modular_api_sqlserver | npm ci + test + build | PASS | vitest passed (14), build executed |
| ts/modular_api_postgres | npm ci + test + build | PASS | vitest passed (14), build executed |
| py/modular_api_rest_client | pip editable install + python -m pytest | PASS | 7 passed |
| py/modular_api_graphql_client | pip editable install + python -m pytest | PASS | 7 passed |
| py/modular_api_sqlserver | pip editable install + python -m pytest | PASS | 14 passed |
| py/modular_api_postgres | pip editable install + python -m pytest | PASS | 14 passed |

## Publish Readiness Observations

- TypeScript complementary packages are now publishable (`private=false`).
- Dart GraphQL/Postgres packages are now publishable (`publish_to` removed).
- Python workflows now use `python -m pytest` for deterministic execution in CI.
- Release order constraint remains:
  - publish `modular_api_rest_client` before `modular_api_graphql_client` (Dart/TS) so hosted dependency resolution succeeds.
