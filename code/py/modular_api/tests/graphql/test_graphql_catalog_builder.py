"""GraphQL catalog builder tests for Stage 3 naming and source digest."""

from __future__ import annotations

from modular_api.graphql import (
    GraphqlCatalogBuildMode,
    GraphqlCatalogBuilder,
    GraphqlCatalogIdentityMode,
    GraphqlCatalogNaming,
    GraphqlCatalogOrigin,
    GraphqlCatalogRelationCardinality,
    GraphqlFieldMetadata,
    GraphqlMetadataFile,
    GraphqlMetadataLimit,
    GraphqlObjectMetadata,
    GraphqlRelationMetadata,
)
from modular_api.graphql.sqlserver import (
    PhysicalCatalog,
    PhysicalField,
    PhysicalObject,
    PhysicalObjectKind,
    PhysicalRelationSeed,
)


def test_graphql_catalog_naming_tokenizes_separators_casing_acronyms_and_digits_deterministically() -> None:
    assert GraphqlCatalogNaming.type_name_for_object_name("vw_Retiro") == "VwRetiro"
    assert GraphqlCatalogNaming.type_name_for_object_name("retiro-evento") == "RetiroEvento"
    assert GraphqlCatalogNaming.type_name_for_object_name("retiro.evento final") == "RetiroEventoFinal"
    assert GraphqlCatalogNaming.public_field_name_for_column("URL_ARCHIVO") == "urlArchivo"
    assert GraphqlCatalogNaming.public_field_name_for_column("FechaIDCliente") == "fechaIdCliente"
    assert GraphqlCatalogNaming.public_field_name_for_column("cliente#maestro") == "clienteMaestro"
    assert GraphqlCatalogNaming.type_name_for_object_name("cliente2Detalle") == "Cliente2Detalle"


def test_builds_a_governed_catalog_with_deterministic_names_identities_limits_and_ordering() -> None:
    catalog = _builder().build(
        physical_catalog=_physical_catalog(),
        metadata=_metadata(),
    )

    assert catalog.catalog_version == "1.0.0"
    assert catalog.provider.kind == "sql"
    assert catalog.provider.engine == "sqlserver"
    assert catalog.build.mode is GraphqlCatalogBuildMode.RUNTIME
    assert [object_.id for object_ in catalog.objects] == [
        "sales.Customer",
        "sales.EventLog",
        "sales.Order",
        "sales.vw_OrderSummary",
    ]

    customer = next(object_ for object_ in catalog.objects if object_.id == "sales.Customer")
    assert customer.graphql.type_name == "CustomerRecord"
    assert customer.graphql.item_field == "customerRecord"
    assert customer.graphql.collection_field == "customerRecordList"
    assert customer.identity.mode is GraphqlCatalogIdentityMode.SINGLE
    assert customer.identity.origin is GraphqlCatalogOrigin.ANNOTATED
    assert customer.identity.fields == ("CustomerId",)
    assert [field.public_name for field in customer.fields] == [
        "customerCode",
        "customerId",
        "urlArchivo",
    ]
    assert customer.capabilities.item is True
    assert customer.capabilities.collection is True
    assert customer.capabilities.filter is True
    assert customer.capabilities.sort is True
    assert customer.capabilities.pagination.default_limit == 25
    assert customer.capabilities.pagination.max_limit == 100

    event_log = next(object_ for object_ in catalog.objects if object_.id == "sales.EventLog")
    assert event_log.identity.mode is GraphqlCatalogIdentityMode.NONE
    assert event_log.graphql.item_field is None
    assert event_log.capabilities.item is False
    assert event_log.capabilities.collection is True
    assert event_log.capabilities.pagination.default_limit == 50
    assert event_log.capabilities.pagination.max_limit == 200

    summary = next(object_ for object_ in catalog.objects if object_.id == "sales.vw_OrderSummary")
    assert summary.graphql.type_name == "OrderSummary"
    assert summary.graphql.item_field == "orderSummary"
    assert summary.graphql.collection_field == "orderSummaryList"
    assert summary.identity.mode is GraphqlCatalogIdentityMode.SINGLE
    assert summary.identity.origin is GraphqlCatalogOrigin.ANNOTATED
    assert summary.identity.fields == ("OrderId",)
    assert len(summary.relations) == 1
    relation = summary.relations[0]
    assert relation.name == "customer"
    assert relation.cardinality is GraphqlCatalogRelationCardinality.ONE
    assert relation.target == "sales.Customer"
    assert relation.source_fields == ("CustomerId",)
    assert relation.target_fields == ("CustomerId",)
    assert relation.origin is GraphqlCatalogOrigin.ANNOTATED

    assert catalog.diagnostics == ()
    assert catalog.build.source_digest


def test_emits_duplicate_public_name_when_two_fields_derive_the_same_public_name() -> None:
    catalog = _builder().build(
        physical_catalog=PhysicalCatalog(
            objects=(
                PhysicalObject(
                    id="sales.DuplicateNames",
                    kind=PhysicalObjectKind.TABLE,
                    schema_name="sales",
                    object_name="DuplicateNames",
                    identity_fields=("customer_id",),
                    fields=(
                        PhysicalField(column="customer_id", native_type="int", nullable=False),
                        PhysicalField(column="customer.id", native_type="nvarchar(50)", nullable=False),
                    ),
                    relations=(),
                ),
            )
        ),
        metadata=GraphqlMetadataFile(
            version=1,
            objects={
                "sales.DuplicateNames": GraphqlObjectMetadata(
                    publish=True,
                    fields={},
                    relations=(),
                )
            },
        ),
    )

    assert len(catalog.diagnostics) == 1
    assert catalog.diagnostics[0].code == "duplicate_public_name"
    assert catalog.diagnostics[0].object_id == "sales.DuplicateNames"
    assert catalog.diagnostics[0].field == "customerId"


def test_emits_view_missing_identity_when_a_published_view_does_not_declare_usable_identity() -> None:
    catalog = _builder().build(
        physical_catalog=PhysicalCatalog(
            objects=(
                PhysicalObject(
                    id="sales.vw_NoIdentity",
                    kind=PhysicalObjectKind.VIEW,
                    schema_name="sales",
                    object_name="vw_NoIdentity",
                    identity_fields=(),
                    fields=(PhysicalField(column="OrderId", native_type="int", nullable=False),),
                    relations=(),
                ),
            )
        ),
        metadata=GraphqlMetadataFile(
            version=1,
            objects={
                "sales.vw_NoIdentity": GraphqlObjectMetadata(
                    publish=True,
                    fields={},
                    relations=(),
                )
            },
        ),
    )

    summary = catalog.objects[0]
    assert summary.identity.mode is GraphqlCatalogIdentityMode.NONE
    assert summary.graphql.item_field is None
    assert summary.capabilities.item is False
    assert len(catalog.diagnostics) == 1
    assert catalog.diagnostics[0].code == "view_missing_identity"
    assert catalog.diagnostics[0].object_id == "sales.vw_NoIdentity"


def test_preserves_semantic_order_for_composite_identity_and_relation_key_fields() -> None:
    catalog = _builder().build(
        physical_catalog=PhysicalCatalog(
            objects=(
                PhysicalObject(
                    id="sales.CompositeTarget",
                    kind=PhysicalObjectKind.TABLE,
                    schema_name="sales",
                    object_name="CompositeTarget",
                    identity_fields=("CountryCode", "CustomerCode"),
                    fields=(
                        PhysicalField(column="CountryCode", native_type="nvarchar(2)", nullable=False),
                        PhysicalField(column="CustomerCode", native_type="nvarchar(50)", nullable=False),
                    ),
                    relations=(),
                ),
                PhysicalObject(
                    id="sales.vw_CompositeSource",
                    kind=PhysicalObjectKind.VIEW,
                    schema_name="sales",
                    object_name="vw_CompositeSource",
                    identity_fields=(),
                    fields=(
                        PhysicalField(column="KeyB", native_type="int", nullable=False),
                        PhysicalField(column="KeyA", native_type="int", nullable=False),
                        PhysicalField(column="CountryCode", native_type="nvarchar(2)", nullable=False),
                        PhysicalField(column="CustomerCode", native_type="nvarchar(50)", nullable=False),
                    ),
                    relations=(),
                ),
            )
        ),
        metadata=GraphqlMetadataFile(
            version=1,
            objects={
                "sales.CompositeTarget": GraphqlObjectMetadata(
                    publish=True,
                    fields={},
                    relations=(),
                ),
                "sales.vw_CompositeSource": GraphqlObjectMetadata(
                    publish=True,
                    key=("KeyB", "KeyA"),
                    fields={},
                    relations=(
                        GraphqlRelationMetadata(
                            name="target",
                            cardinality="to-one",
                            target="sales.CompositeTarget",
                            via=("CountryCode", "CustomerCode"),
                        ),
                    ),
                ),
            },
        ),
    )

    source = next(object_ for object_ in catalog.objects if object_.id == "sales.vw_CompositeSource")
    assert source.identity.fields == ("KeyB", "KeyA")
    assert source.relations[0].source_fields == ("CountryCode", "CustomerCode")
    assert source.relations[0].target_fields == ("CountryCode", "CustomerCode")
    assert catalog.diagnostics == ()


def test_keeps_source_digest_stable_across_semantically_identical_input_order_and_changes_it_on_relevant_input_changes() -> None:
    first = _builder().build(
        physical_catalog=_physical_catalog(),
        metadata=_metadata(),
    )
    second = _builder().build(
        physical_catalog=PhysicalCatalog(objects=tuple(reversed(_physical_catalog().objects))),
        metadata=GraphqlMetadataFile(
            version=_metadata().version,
            defaults_limit=_metadata().defaults_limit,
            objects=dict(reversed(tuple(_metadata().objects.items()))),
        ),
    )
    changed = _builder().build(
        physical_catalog=_physical_catalog(),
        metadata=GraphqlMetadataFile(
            version=_metadata().version,
            defaults_limit=_metadata().defaults_limit,
            objects={
                key: (
                    GraphqlObjectMetadata(
                        publish=value.publish,
                        name="CustomerRenamed",
                        key=value.key,
                        fields=value.fields,
                        relations=value.relations,
                        limit=value.limit,
                    )
                    if key == "sales.Customer"
                    else value
                )
                for key, value in _metadata().objects.items()
            },
        ),
    )

    assert first.build.source_digest == second.build.source_digest
    assert first.build.source_digest != changed.build.source_digest


def _builder() -> GraphqlCatalogBuilder:
    return GraphqlCatalogBuilder(
        provider_version="0.4.7-test",
        source_root="db/src",
        build_mode=GraphqlCatalogBuildMode.RUNTIME,
        engine="sqlserver",
    )


def _metadata() -> GraphqlMetadataFile:
    return GraphqlMetadataFile(
        version=1,
        defaults_limit=GraphqlMetadataLimit(default_value=50, max_value=200),
        objects={
            "sales.Customer": GraphqlObjectMetadata(
                publish=True,
                name="CustomerRecord",
                key=("CustomerId",),
                fields={
                    "CustomerCode": GraphqlFieldMetadata(name="customerCode"),
                },
                relations=(),
                limit=GraphqlMetadataLimit(default_value=25, max_value=100),
            ),
            "sales.EventLog": GraphqlObjectMetadata(
                publish=True,
                fields={},
                relations=(),
            ),
            "sales.Order": GraphqlObjectMetadata(
                publish=True,
                fields={},
                relations=(),
            ),
            "sales.vw_OrderSummary": GraphqlObjectMetadata(
                publish=True,
                name="OrderSummary",
                key=("OrderId",),
                fields={},
                relations=(
                    GraphqlRelationMetadata(
                        name="customer",
                        cardinality="to-one",
                        target="sales.Customer",
                        via=("CustomerId",),
                    ),
                ),
            ),
        },
    )


def _physical_catalog() -> PhysicalCatalog:
    return PhysicalCatalog(
        objects=(
            PhysicalObject(
                id="sales.Order",
                kind=PhysicalObjectKind.TABLE,
                schema_name="sales",
                object_name="Order",
                identity_fields=("OrderId",),
                fields=(
                    PhysicalField(column="OrderId", native_type="int", nullable=False),
                    PhysicalField(column="CustomerId", native_type="int", nullable=False),
                    PhysicalField(column="TotalAmount", native_type="decimal(18,2)", nullable=False),
                ),
                relations=(
                    PhysicalRelationSeed(
                        name="Customer",
                        source_object_id="sales.Order",
                        target_object_id="sales.Customer",
                        source_fields=("CustomerId",),
                        target_fields=("CustomerId",),
                    ),
                ),
            ),
            PhysicalObject(
                id="sales.Customer",
                kind=PhysicalObjectKind.TABLE,
                schema_name="sales",
                object_name="Customer",
                identity_fields=("CustomerId",),
                fields=(
                    PhysicalField(column="CustomerId", native_type="int", nullable=False),
                    PhysicalField(column="CustomerCode", native_type="nvarchar(50)", nullable=False),
                    PhysicalField(column="URLArchivo", native_type="nvarchar(255)", nullable=True),
                ),
                relations=(),
            ),
            PhysicalObject(
                id="sales.vw_OrderSummary",
                kind=PhysicalObjectKind.VIEW,
                schema_name="sales",
                object_name="vw_OrderSummary",
                identity_fields=(),
                fields=(
                    PhysicalField(column="OrderId", native_type="int", nullable=False),
                    PhysicalField(column="CustomerId", native_type="int", nullable=False),
                    PhysicalField(column="HasNotes", native_type="bit", nullable=True),
                ),
                relations=(),
            ),
            PhysicalObject(
                id="sales.EventLog",
                kind=PhysicalObjectKind.TABLE,
                schema_name="sales",
                object_name="EventLog",
                identity_fields=(),
                fields=(
                    PhysicalField(column="CreatedAt", native_type="datetime2", nullable=False),
                    PhysicalField(column="PayloadJson", native_type="nvarchar(max)", nullable=True),
                ),
                relations=(),
            ),
        )
    )