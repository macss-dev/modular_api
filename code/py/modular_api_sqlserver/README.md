# macss-modular-api-sqlserver

Official MACSS SQL Server integration package for Python.

## Quick start

```python
from modular_api_sqlserver import DbClient, DbCommand, DbCommandKind, DbConnectionSettings

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

## Current slice

- normalized SQL Server connection defaults and redacted summaries
- engine-agnostic `DbClient`, `DbRepository`, and transaction contracts
- explicit lease ownership semantics for package-owned and application-owned sessions
- health contributor and GraphQL support bundle for higher-level integrations
- real driver bindings intentionally remain outside this first slice