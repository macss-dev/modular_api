# @macss/modular-api-postgres

Official MACSS Postgres integration package for TypeScript.

## Quick start

```ts
import { DbClient, DbCommand, DbCommandKind, DbConnectionSettings } from '@macss/modular-api-postgres';

const settings = DbConnectionSettings.fromEnvironment();

const client = new DbClient({
  settings,
  sessionProvider: mySessionProvider,
  commandExecutor: myCommandExecutor,
  transactionRunner: myTransactionRunner,
});

const result = await client.scalar<number>(
  new DbCommand({
    kind: DbCommandKind.scalar,
    text: 'select count(*) from users',
    label: 'users.count',
  }),
);

if (result.isSuccess) {
  console.log(result.value.value);
} else {
  console.error(result.failure.message);
}
```

See [example/example.ts](example/example.ts) for a complete in-memory wiring sample.

## What this package provides

- normalized Postgres connection defaults and redacted summaries
- engine-agnostic `DbClient`, `DbRepository`, and transaction contracts
- explicit lease ownership semantics for package-owned and application-owned sessions
- health contributor and GraphQL support bundle for higher-level integrations
- the application supplies the driver binding (adapter) for its chosen engine and driver

This package is **contracts-only by design** and will never ship a driver binding; you choose your engine and driver and provide the adapter. See [ADR-0004](../../../docs/adr/0004-contracts-only-database-packages.md).