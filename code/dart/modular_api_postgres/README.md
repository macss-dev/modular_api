# modular_api_postgres

Official MACSS Postgres integration package for Dart.

## Quick start

```dart
import 'package:modular_api_postgres/modular_api_postgres.dart';

final settings = DbConnectionSettings.fromEnvironment();

final client = DbClient<String>(
  settings: settings,
  sessionProvider: mySessionProvider,
  commandExecutor: myCommandExecutor,
  transactionRunner: myTransactionRunner,
);

final result = await client.scalar<int>(
  const DbCommand(
    kind: DbCommandKind.scalar,
    text: 'select count(*) from users',
    label: 'users.count',
  ),
);

if (result.isSuccess) {
  print(result.value.value);
} else {
  print(result.failure.message);
}
```

See [example/example.dart](example/example.dart) for a complete in-memory wiring sample.

## What this package provides

- normalized Postgres connection defaults and redacted summaries
- engine-agnostic `DbClient`, `DbRepository`, and transaction contracts
- explicit lease ownership semantics for package-owned and application-owned sessions
- health contributor and GraphQL support bundle for higher-level integrations
- the application supplies the driver binding (adapter) for its chosen engine and driver

This package is **contracts-only by design** and will never ship a driver binding; you choose your engine and driver and provide the adapter. See [ADR-0004](../../../docs/adr/0004-contracts-only-database-packages.md).