# @macss/modular-api-sqlserver

Official MACSS SQL Server integration package for TypeScript.

## Quick start

```ts
import { DbClient, DbCommand, DbCommandKind, DbConnectionSettings } from '@macss/modular-api-sqlserver';

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

## Current slice

- normalized SQL Server connection defaults and redacted summaries
- engine-agnostic `DbClient`, `DbRepository`, and transaction contracts
- explicit lease ownership semantics for package-owned and application-owned sessions
- health contributor and GraphQL support bundle for higher-level integrations
- real driver bindings intentionally remain outside this first slice