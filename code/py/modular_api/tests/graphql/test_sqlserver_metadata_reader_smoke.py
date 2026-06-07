"""SQL Server metadata reader smoke tests against the shared Docker fixture."""

from __future__ import annotations

import pytest

pytest.importorskip("pyodbc")

from modular_api.graphql.sqlserver import (
    PhysicalCatalog,
    PhysicalObject,
    PhysicalObjectKind,
    SqlServerConnectionSettings,
    SqlServerMetadataReader,
)


def test_returns_table_columns_with_normalized_native_types_primary_keys_and_foreign_keys() -> None:
    catalog = _introspect_stage1_fixture()

    customer = next((obj for obj in catalog.objects if obj.id == "sales.Customer"), None)
    assert customer is not None
    assert customer.kind is PhysicalObjectKind.TABLE
    assert customer.identity_fields == ("CustomerId",)
    assert _field_snapshot(customer) == [
        {"column": "CustomerId", "native_type": "int", "nullable": False},
        {"column": "CustomerCode", "native_type": "nvarchar(20)", "nullable": False},
        {"column": "FullName", "native_type": "nvarchar(120)", "nullable": False},
        {"column": "CreatedAt", "native_type": "datetime2(7)", "nullable": False},
        {"column": "IsActive", "native_type": "bit", "nullable": False},
    ]

    order = next((obj for obj in catalog.objects if obj.id == "sales.Order"), None)
    assert order is not None
    assert _field_snapshot(order) == [
        {"column": "OrderId", "native_type": "uniqueidentifier", "nullable": False},
        {"column": "CustomerId", "native_type": "int", "nullable": False},
        {"column": "TotalAmount", "native_type": "decimal(18,2)", "nullable": False},
        {"column": "Notes", "native_type": "nvarchar(200)", "nullable": True},
        {"column": "CreatedAt", "native_type": "datetime2(7)", "nullable": False},
    ]
    assert _relation_snapshot(order) == [
        {
            "name": "FK_Order_Customer",
            "source_object_id": "sales.Order",
            "target_object_id": "sales.Customer",
            "source_fields": ("CustomerId",),
            "target_fields": ("CustomerId",),
        }
    ]


def test_returns_view_columns_with_projected_native_types_and_nullability_from_real_metadata() -> None:
    catalog = _introspect_stage1_fixture()

    summary = next((obj for obj in catalog.objects if obj.id == "sales.vw_OrderSummary"), None)
    assert summary is not None
    assert summary.kind is PhysicalObjectKind.VIEW
    assert _field_snapshot(summary) == [
        {"column": "OrderId", "native_type": "uniqueidentifier", "nullable": False},
        {"column": "CustomerId", "native_type": "int", "nullable": False},
        {"column": "CustomerCode", "native_type": "nvarchar(20)", "nullable": False},
        {"column": "FullName", "native_type": "nvarchar(120)", "nullable": False},
        {"column": "TotalAmount", "native_type": "decimal(18,2)", "nullable": False},
        {"column": "HasNotes", "native_type": "bit", "nullable": True},
        {"column": "CreatedAt", "native_type": "datetime2(7)", "nullable": False},
    ]
    assert summary.identity_fields == ()


def test_is_stable_across_repeated_introspection_of_the_same_prepared_database_state() -> None:
    first = _introspect_stage1_fixture()
    second = _introspect_stage1_fixture()

    assert _catalog_snapshot(first) == _catalog_snapshot(second)


def test_keeps_logical_object_identity_without_requiring_file_path_provenance() -> None:
    catalog = _introspect_stage1_fixture()
    customer = next((obj for obj in catalog.objects if obj.id == "sales.Customer"), None)

    assert customer is not None
    assert customer.schema_name == "sales"
    assert customer.object_name == "Customer"
    assert customer.id == "sales.Customer"


def _introspect_stage1_fixture() -> PhysicalCatalog:
    reader = SqlServerMetadataReader(
        connection=SqlServerConnectionSettings.from_environment(),
    )
    return reader.introspect(schema_names={"sales"})


def _field_snapshot(object_: PhysicalObject) -> list[dict[str, object]]:
    return [
        {
            "column": field.column,
            "native_type": field.native_type,
            "nullable": field.nullable,
        }
        for field in object_.fields
    ]


def _catalog_snapshot(catalog: PhysicalCatalog) -> dict[str, object]:
    return {
        "objects": [
            {
                "id": object_.id,
                "kind": object_.kind.value,
                "schema_name": object_.schema_name,
                "object_name": object_.object_name,
                "identity_fields": object_.identity_fields,
                "fields": _field_snapshot(object_),
                "relations": _relation_snapshot(object_),
            }
            for object_ in catalog.objects
        ],
    }


def _relation_snapshot(object_: PhysicalObject) -> list[dict[str, object]]:
    return [
        {
            "name": relation.name,
            "source_object_id": relation.source_object_id,
            "target_object_id": relation.target_object_id,
            "source_fields": relation.source_fields,
            "target_fields": relation.target_fields,
        }
        for relation in object_.relations
    ]