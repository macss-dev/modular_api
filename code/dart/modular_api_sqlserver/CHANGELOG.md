# Changelog

## 0.5.0

- version bump for cross-SDK parity (ADR-0002); no functional changes
- update `modular_api` dependency to `^0.5.0`

## 0.4.8

- switch `modular_api` dependency from local path to published `^0.4.8`
- keep SQL Server metadata reader and connection settings in this package as the clean-room owner

## 0.4.7

- bootstrap `modular_api_sqlserver` for Dart
- add the first SQL Server database client slice with shared contracts, repository helpers, and health support
- add tests for defaults, result helpers, lease ownership, transactions, close flows, and GraphQL support bundling