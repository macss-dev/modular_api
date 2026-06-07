"""GraphQL metadata parser tests for Stage 2 sidecar validation."""

from __future__ import annotations

from modular_api.graphql.metadata import GraphqlMetadataParser, GraphqlMetadataSeverity
from modular_api.graphql.sqlserver import (
    PhysicalCatalog,
    PhysicalObject,
    PhysicalObjectKind,
)


def test_parses_jsonc_and_emits_view_missing_identity_for_published_views_without_key() -> None:
    parser = GraphqlMetadataParser()

    result = parser.parse(
        raw_jsonc="""
{
  // JSONC comment
  version: 1,
  objects: {
    "sales.vw_OrderSummary": {
      publish: true,
    },
  },
}
""",
        physical_catalog=_physical_catalog(),
    )

    assert result.metadata is not None
    assert result.metadata.version == 1
    assert tuple(result.metadata.objects.keys()) == ("sales.vw_OrderSummary",)
    assert len(result.diagnostics) == 1
    assert result.diagnostics[0].severity is GraphqlMetadataSeverity.ERROR
    assert result.diagnostics[0].code == "view_missing_identity"
    assert result.diagnostics[0].object_id == "sales.vw_OrderSummary"


def test_emits_metadata_object_unknown_for_declared_objects_absent_from_the_physical_model() -> None:
    parser = GraphqlMetadataParser()

    result = parser.parse(
        raw_jsonc="""
{
  version: 1,
  objects: {
    "sales.Missing": {
      publish: true,
    },
  },
}
""",
        physical_catalog=_physical_catalog(),
    )

    assert result.metadata is not None
    assert tuple(result.metadata.objects.keys()) == ("sales.Missing",)
    assert len(result.diagnostics) == 1
    assert result.diagnostics[0].code == "metadata_object_unknown"
    assert result.diagnostics[0].object_id == "sales.Missing"


def test_rejects_defaults_and_object_limits_where_default_is_greater_than_max() -> None:
    parser = GraphqlMetadataParser()

    result = parser.parse(
        raw_jsonc="""
{
  version: 1,
  defaults: {
    limit: { default: 200, max: 50 },
  },
  objects: {
    "sales.Customer": {
      publish: true,
      limit: { default: 100, max: 25 },
    },
  },
}
""",
        physical_catalog=_physical_catalog(),
    )

    assert [diagnostic.code for diagnostic in result.diagnostics] == [
        "metadata_invalid_shape",
        "metadata_invalid_shape",
    ]
    assert len([d for d in result.diagnostics if d.field == "defaults.limit"]) == 1
    assert len([d for d in result.diagnostics if d.field == "sales.Customer.limit"]) == 1


def test_sorts_mixed_error_and_warning_diagnostics_canonically() -> None:
    parser = GraphqlMetadataParser()

    result = parser.parse(
        raw_jsonc="""
{
  version: 1,
  futureKey: true,
  objects: {
    "sales.Unknown": {
      publish: true,
      stray: true,
    },
    "sales.vw_OrderSummary": {
      publish: true,
    },
  },
}
""",
        physical_catalog=_physical_catalog(),
    )

    assert [
        f"{diagnostic.severity.value}|{diagnostic.code}|{diagnostic.object_id or ''}|{diagnostic.field or ''}"
        for diagnostic in result.diagnostics
    ] == [
        "error|metadata_object_unknown|sales.Unknown|",
        "error|view_missing_identity|sales.vw_OrderSummary|",
        "warning|metadata_unknown_key||futureKey",
        "warning|metadata_unknown_key|sales.Unknown|stray",
    ]


def test_keeps_a_strict_allowlist_of_declared_publish_true_objects_and_leaves_absent_objects_unpublished() -> None:
    parser = GraphqlMetadataParser()

    result = parser.parse(
        raw_jsonc="""
{
  version: 1,
  objects: {
    "sales.Customer": {
      publish: true,
    },
  },
}
""",
        physical_catalog=_physical_catalog(),
    )

    assert result.metadata is not None
    assert tuple(result.metadata.objects.keys()) == ("sales.Customer",)
    assert "sales.vw_OrderSummary" not in result.metadata.objects
    assert result.diagnostics == ()


def test_parses_field_relation_and_limit_overrides_into_strongly_typed_metadata() -> None:
    parser = GraphqlMetadataParser()

    result = parser.parse(
        raw_jsonc="""
{
  version: 1,
  defaults: {
    limit: { default: 50, max: 200 },
  },
  objects: {
    "sales.Customer": {
      publish: true,
      name: "CustomerRecord",
      key: ["CustomerId"],
      fields: {
        "CustomerCode": {
          hidden: true,
          noFilter: true,
          name: "customerCode",
        },
        "FullName": {
          sensitive: true,
          noSort: true,
        },
      },
      relations: [
        {
          name: "orders",
          cardinality: "to-many",
          target: "sales.Order",
          via: ["CustomerId"],
        },
      ],
      limit: { default: 25, max: 100 },
    },
  },
}
""",
        physical_catalog=_physical_catalog(),
    )

    assert result.metadata is not None
    customer = result.metadata.objects["sales.Customer"]
    assert customer.name == "CustomerRecord"
    assert customer.key == ("CustomerId",)
    assert result.metadata.defaults_limit is not None
    assert result.metadata.defaults_limit.default_value == 50
    assert result.metadata.defaults_limit.max_value == 200
    assert customer.limit is not None
    assert customer.limit.default_value == 25
    assert customer.limit.max_value == 100
    assert tuple(customer.fields.keys()) == ("CustomerCode", "FullName")
    assert customer.fields["CustomerCode"].hidden is True
    assert customer.fields["CustomerCode"].no_filter is True
    assert customer.fields["CustomerCode"].name == "customerCode"
    assert customer.fields["FullName"].sensitive is True
    assert customer.fields["FullName"].no_sort is True
    assert len(customer.relations) == 1
    assert customer.relations[0].name == "orders"
    assert customer.relations[0].cardinality == "to-many"
    assert customer.relations[0].target == "sales.Order"
    assert customer.relations[0].via == ("CustomerId",)
    assert result.diagnostics == ()


def _physical_catalog() -> PhysicalCatalog:
    return PhysicalCatalog(
        objects=(
            PhysicalObject(
                id="sales.Customer",
                kind=PhysicalObjectKind.TABLE,
                schema_name="sales",
                object_name="Customer",
                identity_fields=("CustomerId",),
                fields=(),
                relations=(),
            ),
            PhysicalObject(
                id="sales.vw_OrderSummary",
                kind=PhysicalObjectKind.VIEW,
                schema_name="sales",
                object_name="vw_OrderSummary",
                identity_fields=(),
                fields=(),
                relations=(),
            ),
        )
    )