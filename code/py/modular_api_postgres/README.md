# macss-modular-api-postgres

Official MACSS Postgres integration package for Python.

## Quick start

```python
from modular_api_postgres import DbClient, DbCommand, DbCommandKind, DbConnectionSettings

settings = DbConnectionSettings.from_environment()

client = DbClient(
    settings=settings,
    session_provider=my_session_provider,
    command_executor=my_command_executor,
    transaction_runner=my_transaction_runner,
)

result = client.scalar(
    DbCommand(
        kind=DbCommandKind.SCALAR,
        text="select count(*) from users",
        label="users.count",
    )
)

if result.is_success:
    print(result.value.value)
else:
    print(result.failure.message)
```

See [example/example.py](example/example.py) for a complete in-memory wiring sample.

## What this package provides

- normalized Postgres connection defaults and redacted summaries
- engine-agnostic `DbClient`, `DbRepository`, and transaction contracts
- explicit lease ownership semantics for package-owned and application-owned sessions
- health contributor and GraphQL support bundle for higher-level integrations
- the application supplies the driver binding (adapter) for its chosen engine and driver

This package is **contracts-only by design** and will never ship a driver binding; you choose your engine and driver and provide the adapter. See [ADR-0004](../../../docs/adr/0004-contracts-only-database-packages.md).