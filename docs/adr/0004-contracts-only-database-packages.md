# 4. Contracts-Only Database Packages (No Driver Bindings)

Date: 2026-06-13

## Status

Accepted

## Context

The database packages (`modular_api_sqlserver`, `modular_api_postgres`, in all three SDKs)
ship engine-agnostic contracts: `DbClient`, `DbRepository`, `DbSessionProvider`,
`DbCommandExecutor`, `DbTransactionRunner`, `DbCommand`, the `DbFailureKind` taxonomy, and the
related value objects. They do **not** include code that talks to a real database. To use a
`DbClient`, the application injects three collaborators (session provider, command executor,
transaction runner) implemented over the driver of its choice — the adapter.

Until now each package README described this as a "first slice", with the line *"real driver
bindings intentionally remain outside this first slice"*. That phrasing implied official driver
bindings were coming later. They are not.

A specification experiment (X4) validated the contracts against a production SQL Server instance:
stored-procedure calls and `VARBINARY(MAX)` round-trips through an application-supplied `mssql`
adapter of ~150 lines. The contracts held; the experiment also surfaced two contract gaps (typed
parameters and stored-procedure support) which are closed additively in 0.6.0 (see issue #22).
The experiment confirmed that the right place for engine/driver specifics is the application's
adapter, not the package.

## Decision

1. **The database packages are contracts-only, permanently.** The framework will never publish a
   driver binding and the packages will never declare a runtime dependency on a database driver.
   The application chooses its engine and driver and supplies the adapter. A reference adapter is
   documented in [docs/guides/db-adapter.md](../guides/db-adapter.md).

2. **Contract evolution is allowed; driver coupling is not.** Improvements that make the contract
   express real-world database usage better — typed parameters (`DbParameter`), stored procedures
   (`DbCommandKind.procedure`, `DbProcedureOutcome`) in 0.6.0 — are welcome because they keep the
   package free of any driver import. The free-form `typeHint` on `DbParameter` is interpreted by
   the adapter, so the package imports no driver types.

3. **Direction: converge toward a single contracts package per SDK.** The `sqlserver` and
   `postgres` contracts are identical except for `DbConnectionSettings` (`driver` vs `sslMode`).
   The intended evolution is a unified `modular_api_sql` (and, later, `modular_api_nosql`) per
   SDK, dropping the per-engine split. This *reduces* the package count (the six db packages
   become three) — a refinement of what already exists, not a new capability. No target version is
   committed; consistent with the roadmap's stance that releases up to 1.0.0 are fixes or
   improvements of the already-implemented architecture.

4. **Known debt that temporarily contradicts this stance**, to be remedied in dedicated
   iterations (never by adding a driver binding):
   - **#23** — the Python db contracts are synchronous while the rest of the Python SDK is
     async/ASGI; they must move to `async`.
   - **#24** — the Dart `modular_api_sqlserver` package hard-depends on `dart_odbc` through
     `SqlServerMetadataReader`. The fix is to *remove* the driver from the package (the
     driver-backed metadata reader becomes the user's responsibility or a docs example), not to
     wrap it in a new satellite package.

## Consequences

- **The application owns a small adapter** (~150 lines, validated in production by the Fotos API).
  This is the canonical usage pattern, not transitional scaffolding.
- **Maximum freedom, minimum surface** — consumers pick any engine and driver; the framework
  carries no driver dependency, version skew, or transitive footprint.
- **READMEs no longer promise bindings** — the "Current slice" section is renamed and points here.
- **Driver-backed introspection is out of scope for the packages** — a schema metadata reader that
  needs a driver belongs to the consumer or to documentation, consistent with point 4 (#24).
- **Parity remains coordinated** — per ADR-0002, all ecosystem packages move together; a
  contracts-only change still ships as a synchronized version bump.
