# Changelog

## 0.6.0

- add typed command parameters via `DbParameter` (name, value, direction input/output/inputOutput, free-form `typeHint`) with `input`/`output`/`inputOutput` helpers
- add `DbCommandKind.procedure` for stored-procedure execution (the adapter maps it to EXEC/CALL; rows via `query`, no-rows via `execute`)
- add optional `DbProcedureOutcome` (returnValue, outputParameters) on `DbRowSet` and `DbExecutionSummary`
- extend shared-fixture conformance coverage for the new contracts across the three SDKs
- additive and non-breaking: `DbCommand` keeps its signature (parameters already accept any value)
- update `modular_api` dependency to `^0.6.0`

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