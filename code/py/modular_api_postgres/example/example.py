from modular_api_postgres import (
    DbClient,
    DbCommand,
    DbCommandKind,
    DbConnectionSettings,
    DbExecutionMetadata,
    DbExecutionSummary,
    DbProviderDescription,
    DbResult,
    DbRowSet,
    DbScalar,
    DbSessionLease,
)


def main() -> None:
    settings = DbConnectionSettings.from_environment(
        {
            "MODULAR_API_POSTGRES_HOST": "db.local",
            "MODULAR_API_POSTGRES_PASSWORD": "not-printed",
        }
    )

    client = DbClient(
        settings=settings,
        session_provider=_FakeSessionProvider(settings),
        command_executor=_FakeCommandExecutor(),
        transaction_runner=_PassthroughTransactionRunner(),
    )

    result = client.scalar(
        DbCommand(
            kind=DbCommandKind.SCALAR,
            text="select count(*) from users",
            label="users.count",
        )
    )

    if result.is_success:
        print(f"Total users: {result.value.value}")
        return

    print(result.failure.message)


class _FakeSessionProvider:
    def __init__(self, settings: DbConnectionSettings) -> None:
        self._settings = settings

    def acquire(self) -> DbResult[DbSessionLease[str]]:
        return DbResult.success(
            DbSessionLease(
                session="session-1",
                owned_by_package=True,
                releaser=lambda: DbResult.success(None),
            )
        )

    def close(self) -> DbResult[None]:
        return DbResult.success(None)

    def describe(self) -> DbProviderDescription:
        return DbProviderDescription(
            engine_id=self._settings.engine_id,
            database=self._settings.database,
            redacted_summary=self._settings.redacted_summary,
            owns_resources=True,
        )


class _FakeCommandExecutor:
    def query(self, session: str, command: DbCommand) -> DbResult[DbRowSet]:
        del session, command
        return DbResult.success(
            DbRowSet(
                rows=[{"id": 1}],
                metadata=DbExecutionMetadata(duration=0, row_count=1),
            )
        )

    def execute(self, session: str, command: DbCommand) -> DbResult[DbExecutionSummary]:
        del session, command
        return DbResult.success(
            DbExecutionSummary(
                affected_count=1,
                metadata=DbExecutionMetadata(duration=0),
            )
        )

    def scalar(self, session: str, command: DbCommand) -> DbResult[DbScalar[int]]:
        del session
        return DbResult.success(
            DbScalar(
                value=42,
                metadata=DbExecutionMetadata(duration=0, command_label=command.label),
            )
        )


class _PassthroughTransactionRunner:
    def run(self, context, body):
        return body(context)


if __name__ == "__main__":
    main()