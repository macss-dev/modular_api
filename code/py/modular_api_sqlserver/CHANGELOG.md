# Changelog

## 0.6.0

- add typed command parameters via `DbParameter` (name, value, direction input/output/inputOutput, free-form `typeHint`) with `input`/`output`/`inputOutput` helpers
- add `DbCommandKind.procedure` for stored-procedure execution (the adapter maps it to EXEC/CALL; rows via `query`, no-rows via `execute`)
- add optional `DbProcedureOutcome` (returnValue, outputParameters) on `DbRowSet` and `DbExecutionSummary`
- extend shared-fixture conformance coverage for the new contracts across the three SDKs
- additive and non-breaking: `DbCommand` keeps its signature (parameters already accept any value)

## 0.5.0

- version bump for cross-SDK parity (ADR-0002); no functional changes

## 0.4.7

- bootstrap `macss-modular-api-sqlserver`
- add the first SQL Server database client slice with shared contracts, repository helpers, and health support
- add tests for defaults, result helpers, lease ownership, transactions, close flows, and GraphQL support bundling