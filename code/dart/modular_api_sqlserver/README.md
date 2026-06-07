# modular_api_sqlserver

Official MACSS SQL Server integration package for Dart.

## Quick start

```dart
import 'package:modular_api_sqlserver/modular_api_sqlserver.dart';

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

## Current slice

- normalized SQL Server connection defaults and redacted summaries
- engine-agnostic `DbClient`, `DbRepository`, and transaction contracts
- explicit lease ownership semantics for package-owned and application-owned sessions
- health contributor and GraphQL support bundle for higher-level integrations
- real driver bindings intentionally remain outside this first slice