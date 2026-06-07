from __future__ import annotations

import json
from pathlib import Path

from modular_api_postgres import DbConnectionSettings, DbFailure, DbFailureKind, DbResult


def _load_fixture() -> dict[str, object]:
    return json.loads(
        (Path(__file__).resolve().parents[3] / "tests" / "fixtures" / "db_client" / "postgres.json").read_text(
            encoding="utf-8"
        )
    )


def test_matches_the_shared_postgres_connection_fixture() -> None:
    fixture = _load_fixture()
    connection = fixture["connection"]
    expected = connection["expected"]

    settings = DbConnectionSettings.from_environment(connection["environment"])

    assert settings.engine_id == expected["engineId"]
    assert settings.host == expected["host"]
    assert settings.port == expected["port"]
    assert settings.database == expected["database"]
    assert settings.username == expected["username"]
    assert settings.password == expected["password"]
    assert settings.ssl_mode == expected["sslMode"]

    for fragment in connection["redactedContains"]:
        assert fragment in settings.redacted_summary
    for fragment in connection["redactedExcludes"]:
        assert fragment not in settings.redacted_summary


def test_matches_the_shared_db_result_fixture() -> None:
    fixture = _load_fixture()
    result_fixture = fixture["result"]

    success = DbResult.success(result_fixture["successValue"])
    failure = DbResult.from_failure(
        DbFailure(
            kind=DbFailureKind.TIMEOUT,
            code=result_fixture["timeoutCode"],
            message="Timed out",
            retryable=True,
            transient=True,
        )
    )

    assert success.map(lambda value: value * 2).value == result_fixture["mappedValue"]
    assert success.flat_map(lambda value: DbResult.success(value + 1)).value == result_fixture[
        "flatMappedValue"
    ]

    mapped_failure = failure.map_failure(
        lambda current: DbFailure(
            kind=current.kind,
            code=result_fixture["wrappedFailureCode"],
            message=current.message,
            retryable=current.retryable,
            transient=current.transient,
        )
    )

    assert mapped_failure.failure.code == result_fixture["wrappedFailureCode"]