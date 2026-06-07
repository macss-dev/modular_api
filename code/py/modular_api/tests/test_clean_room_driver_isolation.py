from pathlib import Path

import pytest

import modular_api.graphql.sqlserver.sql_server_metadata_reader as sqlserver_metadata_reader
from modular_api.graphql.sqlserver import PhysicalCatalog, SqlServerConnectionSettings, SqlServerMetadataReader


def test_core_pyproject_excludes_concrete_database_drivers() -> None:
    contents = Path("pyproject.toml").read_text(encoding="utf-8")

    assert "pyodbc" not in contents
    assert "psycopg" not in contents


def test_core_graphql_sqlserver_surface_imports_without_eager_driver_loading() -> None:
    catalog = PhysicalCatalog(objects=())
    connection = SqlServerConnectionSettings.from_environment(environment={})
    reader = SqlServerMetadataReader(connection=connection, connect=lambda *_args, **_kwargs: None)

    assert catalog.objects == ()
    assert connection.host == "127.0.0.1"
    assert isinstance(reader, SqlServerMetadataReader)


def test_sqlserver_reader_reports_optional_pyodbc_requirement(monkeypatch: pytest.MonkeyPatch) -> None:
    reader = SqlServerMetadataReader(
        connection=SqlServerConnectionSettings.from_environment(environment={})
    )

    def _raise_missing_driver():
        raise RuntimeError(
            'SqlServerMetadataReader requires the optional "pyodbc" package. '
            'Install it to use SQL Server introspection.'
        )

    monkeypatch.setattr(sqlserver_metadata_reader, "_load_pyodbc_connect", _raise_missing_driver)

    with pytest.raises(RuntimeError, match='optional "pyodbc" package'):
        reader.introspect()