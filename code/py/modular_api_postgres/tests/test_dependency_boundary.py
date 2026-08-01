"""Guards the dependency boundary for a satellite package (runbook D21) **and ADR-0004**.

This package does not depend on ``macss-modular-api``, so it cannot inherit the OpenTelemetry API
transitively and must declare it itself. What it must never declare as a runtime dependency is an
OTel SDK, an exporter, grpcio or protobuf: those belong to the application (ADR-0005 A2).
``optional-dependencies`` may carry them, and does — the in-memory exporter is needed to observe
instrumentation at all, since the API alone produces no-op spans (D22).

**The driver guard is the reason this file is new.** ADR-0004 says this package ships contracts and
no database driver, and until now that was enforced by ``dependencies = []`` — an invariant nobody
had to assert because it was structural. Adding the OTel API ends that, so the rule has to become a
test. The runbook expected to extend an existing conformance check; there was none to extend.
"""

from __future__ import annotations

import re
import tomllib
from pathlib import Path

import pytest

_PYPROJECT = Path(__file__).resolve().parents[1] / "pyproject.toml"

_FORBIDDEN_PREFIXES = (
    "opentelemetry-sdk",
    "opentelemetry-exporter",
    "grpcio",
    "protobuf",
)

#: Drivers, not contracts. The reason instrumenting at the contract level is worth anything: every
#: application-supplied adapter is instrumented for free precisely because this package never talks
#: to a database itself.
_DRIVERS = frozenset(
    {
        "psycopg",
        "psycopg2",
        "psycopg2-binary",
        "asyncpg",
        "pg8000",
        "sqlalchemy",
        "pymysql",
        "mysql-connector-python",
        "pyodbc",
        "pymssql",
    }
)


def _requirement_name(requirement: str) -> str:
    return re.split(r"[<>=!~\[\s;]", requirement, maxsplit=1)[0].strip().lower()


@pytest.fixture(scope="module")
def manifest() -> dict[str, object]:
    return tomllib.loads(_PYPROJECT.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def runtime_dependencies(manifest: dict[str, object]) -> list[str]:
    project = manifest["project"]
    assert isinstance(project, dict)
    return list(project["dependencies"])


def test_declares_the_opentelemetry_api_directly(runtime_dependencies: list[str]) -> None:
    names = {_requirement_name(r) for r in runtime_dependencies}

    assert "opentelemetry-api" in names, (
        "this package does not depend on macss-modular-api, so the API cannot arrive "
        "transitively (D21)"
    )


def test_declares_no_sdk_exporter_grpc_or_protobuf(
    runtime_dependencies: list[str],
) -> None:
    offenders = [
        r
        for r in runtime_dependencies
        if _requirement_name(r).startswith(_FORBIDDEN_PREFIXES)
    ]

    assert offenders == [], (
        f"those belong to the application, not the framework (A2). Found: {offenders}"
    )


def test_declares_no_database_driver(runtime_dependencies: list[str]) -> None:
    offenders = [r for r in runtime_dependencies if _requirement_name(r) in _DRIVERS]

    assert offenders == [], (
        f"ADR-0004: this package ships contracts, the application ships the driver. "
        f"Found: {offenders}"
    )


def test_the_api_requirement_is_bounded(runtime_dependencies: list[str]) -> None:
    requirement = next(
        (r for r in runtime_dependencies if _requirement_name(r) == "opentelemetry-api"),
        None,
    )

    assert requirement is not None, "opentelemetry-api is not declared at all (D21)"
    assert re.search(r"<\s*\d", requirement), (
        f"needs an upper bound so a future major cannot arrive silently. Found: {requirement!r}"
    )


def test_a_dev_only_sdk_dependency_does_not_trip_the_guard(
    manifest: dict[str, object],
    runtime_dependencies: list[str],
) -> None:
    project = manifest["project"]
    assert isinstance(project, dict)
    dev = [_requirement_name(r) for r in project["optional-dependencies"]["dev"]]

    assert "opentelemetry-sdk" in dev
    assert "opentelemetry-sdk" not in {_requirement_name(r) for r in runtime_dependencies}
