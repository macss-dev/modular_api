# Changelog

## 0.7.0

- raise the `@macss/modular-api-rest-client` constraint to `^0.7.0`: `^0.6.0` resolves to `>=0.6.0 <0.7.0`, so this package would have shipped at 0.7.0 requiring a 0.6.x @macss/modular-api-rest-client — a version conflict for anyone using both

## 0.6.0

- version bump for cross-SDK parity (ADR-0002); no functional changes
- update `@macss/modular-api-rest-client` dependency to `^0.6.0`

## 0.5.0

- version bump for cross-SDK parity (ADR-0002); no functional changes
- update `@macss/modular-api-rest-client` dependency to `^0.5.0`

## 0.4.7

- bootstrap `@macss/modular-api-graphql-client`
- add the first GraphQL client slice with query-only requests and normalized failures
- add tests for happy path, GraphQL errors, auth injection, timeout, transport failures, and mutation rejection