# Changelog

## 0.7.0

- add database spans: `trace_db_client(client)` wraps a `DbClient` so its commands, transactions and
  session acquisitions produce OpenTelemetry spans
- instrumentation is a decorator over the contract, not a change to `DbClient` — wrapping the
  application-supplied `DbCommandExecutor` covers `DbClient`, `DbRepository` and
  `DbTransactionContext` at once, including commands issued inside a transaction body
- **not wrapping is how you turn tracing off**, so an existing consumer is unaffected and pays nothing
- the SQL text is **not** recorded by default; opt in with
  `DbTracingOptions(include_query_text=True)`. Parameter values are never recorded regardless: the
  text is a template, the parameters are the data
- spans use the **stable** database conventions — `db.system.name`, `db.namespace`,
  `db.operation.name`, `db.query.text`. The deprecated `db.system`, `db.name`, `db.operation` and
  `db.statement` are not emitted
- `db.system.name` is `postgresql`, the value the conventions register — not our `engine_id`, which is
  `postgres`
- session acquisition gets its own `CONNECT` span, so time spent waiting for a connection is
  attributed rather than falling into an unexplained gap
- **this package is no longer dependency-free**: it declares `opentelemetry-api` directly, because it
  does not depend on `macss-modular-api` and so cannot inherit it (runbook D21). It still declares no
  OTel SDK, exporter, grpcio or protobuf — those belong to the application (ADR-0005 A2) — and no
  database driver, which ADR-0004 requires and a new test now asserts

## 0.6.0

- add typed command parameters via `DbParameter` (name, value, direction input/output/inputOutput, free-form `typeHint`) with `input`/`output`/`inputOutput` helpers
- add `DbCommandKind.procedure` for stored-procedure execution (the adapter maps it to EXEC/CALL; rows via `query`, no-rows via `execute`)
- add optional `DbProcedureOutcome` (returnValue, outputParameters) on `DbRowSet` and `DbExecutionSummary`
- extend shared-fixture conformance coverage for the new contracts across the three SDKs
- additive and non-breaking: `DbCommand` keeps its signature (parameters already accept any value)

## 0.5.0

- version bump for cross-SDK parity (ADR-0002); no functional changes

## 0.4.7

- bootstrap `macss-modular-api-postgres`
- add the first Postgres database client slice with shared contracts, repository helpers, and health support
- add tests for defaults, result helpers, lease ownership, transactions, close flows, and GraphQL support bundling