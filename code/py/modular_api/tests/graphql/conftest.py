"""Shared configuration for the GraphQL test package.

The SQL Server smoke tests exercise a real database — the shared Docker fixture
listening on port 14333 — and are the only tests in any of the three SDKs that
require external infrastructure. Until now, running the suite without that
server produced five ``pyodbc.OperationalError`` failures. A suite that reports
failures for absent infrastructure trains the reader to ignore a red result,
which is precisely how a genuine regression hides.

They now skip with an explicit reason. The policy is the one the rest of the
ecosystem already follows: a test whose infrastructure is missing has not
failed, it has not run. ``pytest.importorskip("pyodbc")`` in these modules
already covered the "driver not installed" half of the problem; this covers the
"driver installed, server unreachable" half.

Reachability is probed once per session and cached, so an unavailable server
costs one connection timeout instead of one per test.

Set ``MODULAR_API_SQLSERVER_*`` (see :func:`sqlserver_connection_string`) to
point the smoke tests at a live instance.
"""

from __future__ import annotations

import functools
import os
from collections.abc import Iterator
from typing import TYPE_CHECKING

import pytest

if TYPE_CHECKING:
    import pyodbc  # pyright: ignore[reportMissingImports]


def sqlserver_connection_string() -> str:
    """Build the ODBC connection string for the shared SQL Server fixture."""
    driver = os.getenv("MODULAR_API_SQLSERVER_DRIVER", "ODBC Driver 17 for SQL Server")
    host = os.getenv("MODULAR_API_SQLSERVER_HOST", "127.0.0.1")
    port = os.getenv("MODULAR_API_SQLSERVER_PORT", "14333")
    database = os.getenv("MODULAR_API_SQLSERVER_DATABASE", "modular_api_graphql_v1")
    username = os.getenv("MODULAR_API_SQLSERVER_USERNAME", "sa")
    password = os.getenv("MODULAR_API_SQLSERVER_PASSWORD", "ModularApi_dev_StrongPass1")
    return (
        f"DRIVER={{{driver}}};"
        f"SERVER={host},{port};"
        f"DATABASE={database};"
        f"UID={username};"
        f"PWD={password};"
        "Encrypt=no;"
        "TrustServerCertificate=yes;"
    )


@functools.lru_cache(maxsize=1)
def _sqlserver_unavailable_reason() -> str | None:
    """Return why SQL Server cannot be reached, or ``None`` when it can.

    Cached: the probe runs at most once per test session.
    """
    try:
        import pyodbc  # pyright: ignore[reportMissingImports]
    except ImportError:  # pragma: no cover - covered by importorskip in the modules
        return "pyodbc is not installed"

    try:
        pyodbc.connect(sqlserver_connection_string(), timeout=5).close()
    except pyodbc.Error as exc:
        detail = exc.args[0] if exc.args else exc
        return (
            f"SQL Server fixture is not reachable ({detail}). "
            "Start the shared Docker fixture, or set MODULAR_API_SQLSERVER_* to a live instance."
        )
    return None


@pytest.fixture(scope="session")
def require_sqlserver() -> None:
    """Skip the requesting test when the SQL Server fixture is unreachable."""
    reason = _sqlserver_unavailable_reason()
    if reason is not None:
        pytest.skip(reason)


@pytest.fixture(scope="module")
def sqlserver_connection(require_sqlserver: None) -> Iterator[pyodbc.Connection]:
    """An open connection to the shared SQL Server fixture."""
    import pyodbc  # pyright: ignore[reportMissingImports]

    connection = pyodbc.connect(sqlserver_connection_string(), timeout=5)
    try:
        yield connection
    finally:
        connection.close()
