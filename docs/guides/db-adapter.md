# Writing a database adapter

The `modular_api_sqlserver` and `modular_api_postgres` packages are **contracts-only** by design
(see [ADR-0004](../adr/0004-contracts-only-database-packages.md)): they define `DbClient` and its
collaborators but ship no database driver. To run real queries you provide an **adapter** — a thin
implementation of three interfaces over the driver of your choice. This guide shows a reference
adapter for SQL Server using the `mssql` package in TypeScript. The same shape applies to Postgres
(`pg`), to Python (`pyodbc`/`asyncpg`), and to Dart.

The adapter is small (~150 lines in production) and you own it. That is the point: you choose the
engine and driver; the framework stays out of your dependency tree.

## The three collaborators

`DbClient` is constructed with:

- `DbSessionProvider<S>` — `acquire()` a session (a pooled connection) and `close()` the pool.
- `DbCommandExecutor<S>` — run a `DbCommand` via `query()` (rows), `execute()` (affected count),
  or `scalar()` (single value).
- `DbTransactionRunner<S>` — wrap work in a transaction.

`S` is whatever session type your driver exposes. Below, `S = sql.ConnectionPool`.

## Binding parameters (G2) and stored procedures (G3)

A `DbCommand.parameters` entry is either a raw positional value or a `DbParameter`
(`name`, `value`, `direction`, optional free-form `typeHint`). A `DbCommand` with
`kind: DbCommandKind.procedure` names a stored procedure in `text`; your adapter decides how to
invoke it (`request.execute(name)` for `mssql`). Rows come back through `query()`; a procedure with
no result set goes through `execute()`. When the driver exposes a return value or output
parameters, populate the optional `DbProcedureOutcome` on the result.

```ts
import sql from 'mssql';
import {
  DbCommand,
  DbCommandKind,
  DbParameter,
  DbParameterDirection,
  DbProcedureOutcome,
} from '@macss/modular-api-sqlserver';

// Apply DbCommand.parameters to an mssql Request, honouring DbParameter metadata.
function bindParameters(request: sql.Request, command: DbCommand): void {
  command.parameters.forEach((parameter, index) => {
    if (parameter instanceof DbParameter) {
      const type = parameter.typeHint ? resolveType(parameter.typeHint) : undefined;
      if (parameter.direction === DbParameterDirection.output) {
        request.output(parameter.name, type ?? sql.NVarChar);
      } else {
        // input and inputOutput both carry a value
        type ? request.input(parameter.name, type, parameter.value)
             : request.input(parameter.name, parameter.value);
      }
    } else {
      // raw positional value keeps working: bind as p0, p1, ...
      request.input(`p${index}`, parameter);
    }
  });
}

// Map a free-form typeHint to a driver type. The package never imports sql types;
// this lookup lives entirely in your adapter.
function resolveType(typeHint: string): sql.ISqlType | (() => sql.ISqlType) {
  switch (typeHint.toLowerCase()) {
    case 'int':
      return sql.Int;
    case 'varbinary(max)':
      return sql.VarBinary(sql.MAX);
    case 'nvarchar(255)':
      return sql.NVarChar(255);
    default:
      return sql.NVarChar;
  }
}

async function runCommand(pool: sql.ConnectionPool, command: DbCommand) {
  const request = pool.request();
  bindParameters(request, command);

  const result =
    command.kind === DbCommandKind.procedure
      ? await request.execute(command.text)   // EXEC the stored procedure
      : await request.query(command.text);     // plain SQL text

  const outcome = new DbProcedureOutcome({
    returnValue: result.returnValue,
    outputParameters: result.output,
  });

  return { rows: result.recordset ?? [], affected: result.rowsAffected[0] ?? 0, outcome };
}
```

## Classifying failures

Map the driver's error codes to the engine-agnostic `DbFailureKind` taxonomy inside the adapter —
this also stays out of the package. For `mssql`: `ELOGIN → authentication`, `ETIMEOUT → timeout`,
`ESOCKET → connectivity`, SQL number `2812 → notFound`, `2627/2601/547 → constraint`,
`1205 → conflict`. Wrap the rest as `unknown`.

## Why this lives in your code

Driver choice, connection-pool tuning, and error-code mapping are all engine/driver specifics. The
contract deliberately keeps them on your side so the package never pulls a driver into your build.
See [ADR-0004](../adr/0004-contracts-only-database-packages.md) for the rationale and the longer-term
direction toward a single `modular_api_sql` contracts package.
