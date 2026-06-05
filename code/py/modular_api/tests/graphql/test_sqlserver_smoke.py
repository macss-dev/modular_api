"""SQL Server Stage 1 smoke tests against the shared Docker fixture."""

from __future__ import annotations

import os
from collections.abc import Iterator

import pyodbc
import pytest


def _connection_string() -> str:
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


@pytest.fixture(scope="module")
def sqlserver_connection() -> Iterator[pyodbc.Connection]:
    connection = pyodbc.connect(_connection_string(), timeout=5)
    try:
        yield connection
    finally:
        connection.close()


def test_reads_shared_fixture_objects_and_relation_metadata(sqlserver_connection: pyodbc.Connection) -> None:
    cursor = sqlserver_connection.cursor()

    objects = cursor.execute(
        """
        SELECT
          s.name AS schema_name,
          o.name AS object_name,
          CASE o.type
            WHEN 'U' THEN 'table'
            WHEN 'V' THEN 'view'
          END AS object_kind
        FROM sys.objects AS o
        INNER JOIN sys.schemas AS s
          ON s.schema_id = o.schema_id
        WHERE o.type IN ('U', 'V')
          AND s.name = N'sales'
        ORDER BY s.name, o.name;
        """
    ).fetchall()

    assert {
        (row.schema_name, row.object_name, row.object_kind) for row in objects
    } >= {
        ("sales", "Customer", "table"),
        ("sales", "Order", "table"),
        ("sales", "vw_OrderSummary", "view"),
    }

    primary_key_rows = cursor.execute(
        """
        SELECT c.name AS column_name
        FROM sys.key_constraints AS kc
        INNER JOIN sys.index_columns AS ic
          ON ic.object_id = kc.parent_object_id
         AND ic.index_id = kc.unique_index_id
        INNER JOIN sys.columns AS c
          ON c.object_id = ic.object_id
         AND c.column_id = ic.column_id
        WHERE kc.type = 'PK'
          AND kc.parent_object_id = OBJECT_ID(N'sales.Customer')
        ORDER BY ic.key_ordinal;
        """
    ).fetchall()

    assert [row.column_name for row in primary_key_rows] == ["CustomerId"]

    relation_rows = cursor.execute(
        """
        SELECT
          source_object.name AS source_object_name,
          source_column.name AS source_column_name,
          target_object.name AS target_object_name,
          target_column.name AS target_column_name
        FROM sys.foreign_keys AS fk
        INNER JOIN sys.foreign_key_columns AS fkc
          ON fkc.constraint_object_id = fk.object_id
        INNER JOIN sys.objects AS source_object
          ON source_object.object_id = fk.parent_object_id
        INNER JOIN sys.columns AS source_column
          ON source_column.object_id = source_object.object_id
         AND source_column.column_id = fkc.parent_column_id
        INNER JOIN sys.objects AS target_object
          ON target_object.object_id = fk.referenced_object_id
        INNER JOIN sys.columns AS target_column
          ON target_column.object_id = target_object.object_id
         AND target_column.column_id = fkc.referenced_column_id
        WHERE fk.parent_object_id = OBJECT_ID(N'sales.[Order]')
        ORDER BY fk.name, fkc.constraint_column_id;
        """
    ).fetchall()

    assert [
        (
            row.source_object_name,
            row.source_column_name,
            row.target_object_name,
            row.target_column_name,
        )
        for row in relation_rows
    ] == [("Order", "CustomerId", "Customer", "CustomerId")]

    view_columns = cursor.execute(
        """
        SELECT c.name AS column_name
        FROM sys.columns AS c
        WHERE c.object_id = OBJECT_ID(N'sales.vw_OrderSummary')
        ORDER BY c.column_id;
        """
    ).fetchall()

    assert [row.column_name for row in view_columns] == [
        "OrderId",
        "CustomerId",
        "CustomerCode",
        "FullName",
        "TotalAmount",
        "HasNotes",
        "CreatedAt",
    ]