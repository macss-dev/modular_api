"""GraphQL SQL Server read compiler tests for Stage 5."""

from __future__ import annotations

import asyncio

from modular_api.graphql import (
    GraphqlCatalog,
    GraphqlCatalogBuild,
    GraphqlCatalogBuildMode,
    GraphqlCatalogCapabilities,
    GraphqlCatalogField,
    GraphqlCatalogFieldVisibility,
    GraphqlCatalogGraphqlNames,
    GraphqlCatalogIdentity,
    GraphqlCatalogIdentityMode,
    GraphqlCatalogOrigin,
    GraphqlCatalogPagination,
    GraphqlCatalogPaginationMode,
    GraphqlCatalogProvider,
    GraphqlCatalogRelation,
    GraphqlCatalogRelationCardinality,
    GraphqlCatalogSource,
    GraphqlPublishedObject,
    ReadExecutionContext,
    ReadExecutor,
    RowSet,
    SqlCatalogReadDispatcher,
    SqlCollectionSelection,
    SqlCountSelection,
    SqlFilterCondition,
    SqlFilterGroup,
    SqlFilterOperator,
    SqlItemSelection,
    SqlOrderByClause,
    SqlPage,
    SqlReadCommand,
    SqlReadCommandPurpose,
    SqlRelationBatchSelection,
    SqlServerReadCompiler,
    SqlSortDirection,
)
from modular_api.graphql.sqlserver import PhysicalObjectKind


def test_item_query_compiles_to_purpose_item() -> None:
    command = SqlServerReadCompiler().compile_item(
        catalog=_catalog(),
        selection=SqlItemSelection(
            object_id="sales.Customer",
            projected_fields=("customerId", "customerCode"),
            key={"customerId": 42},
        ),
    )

    assert command.engine == "sqlserver"
    assert command.purpose is SqlReadCommandPurpose.ITEM
    assert "SELECT TOP (1)" in command.sql
    assert "FROM [sales].[Customer]" in command.sql
    assert "WHERE [CustomerId] = @p0" in command.sql
    assert len(command.parameters) == 1
    assert command.parameters[0].name == "p0"
    assert command.parameters[0].value == 42


def test_collection_query_compiles_to_purpose_collection_and_keeps_string_semantics_engine_native() -> None:
    command = SqlServerReadCompiler().compile_collection(
        catalog=_catalog(),
        selection=SqlCollectionSelection(
            object_id="sales.Customer",
            projected_fields=("customerId", "customerCode", "isActive"),
            filter=SqlFilterGroup.and_(
                (
                    SqlFilterCondition(
                        field="customerCode",
                        operator=SqlFilterOperator.CONTAINS,
                        value="ACME",
                    ),
                    SqlFilterCondition(
                        field="isActive",
                        operator=SqlFilterOperator.EQ,
                        value=True,
                    ),
                )
            ),
            order_by=(
                SqlOrderByClause(field="customerCode", direction=SqlSortDirection.ASC),
                SqlOrderByClause(field="customerId", direction=SqlSortDirection.DESC),
            ),
            page=SqlPage(limit=25, offset=50),
        ),
    )

    assert command.purpose is SqlReadCommandPurpose.COLLECTION
    assert "FROM [sales].[Customer]" in command.sql
    assert "[CustomerCode] LIKE" in command.sql
    assert "ORDER BY [CustomerCode] ASC, [CustomerId] DESC" in command.sql
    assert "OFFSET @p2 ROWS FETCH NEXT @p3 ROWS ONLY" in command.sql
    assert "LOWER(" not in command.sql
    assert [parameter.value for parameter in command.parameters] == ["ACME", True, 50, 25]


def test_total_count_query_compiles_to_purpose_count() -> None:
    command = SqlServerReadCompiler().compile_count(
        catalog=_catalog(),
        selection=SqlCountSelection(
            object_id="sales.Customer",
            filter=SqlFilterCondition(
                field="isActive",
                operator=SqlFilterOperator.EQ,
                value=True,
            ),
        ),
    )

    assert command.purpose is SqlReadCommandPurpose.COUNT
    assert "SELECT COUNT_BIG(1) AS [totalCount]" in command.sql
    assert "WHERE [IsActive] = @p0" in command.sql
    assert command.parameters[0].value is True


def test_relation_batching_compiles_to_purpose_relation_batch() -> None:
    command = SqlServerReadCompiler().compile_relation_batch(
        catalog=_catalog(),
        selection=SqlRelationBatchSelection(
            source_object_id="sales.Order",
            relation_name="customer",
            projected_fields=("customerId", "customerCode"),
            parent_keys=(
                {"customerId": 1},
                {"customerId": 2},
            ),
        ),
    )

    assert command.purpose is SqlReadCommandPurpose.RELATION_BATCH
    assert "FROM [sales].[Customer]" in command.sql
    assert "WHERE [CustomerId] IN (@p0, @p1)" in command.sql
    assert [parameter.value for parameter in command.parameters] == [1, 2]


def test_eq_null_and_ne_null_are_rejected_in_favor_of_is_null() -> None:
    compiler = SqlServerReadCompiler()

    try:
        compiler.compile_collection(
            catalog=_catalog(),
            selection=SqlCollectionSelection(
                object_id="sales.Customer",
                projected_fields=("customerId",),
                filter=SqlFilterCondition(
                    field="customerCode",
                    operator=SqlFilterOperator.EQ,
                    value=None,
                ),
            ),
        )
    except ValueError:
        pass
    else:
        raise AssertionError("Expected eq null to fail")

    try:
        compiler.compile_collection(
            catalog=_catalog(),
            selection=SqlCollectionSelection(
                object_id="sales.Customer",
                projected_fields=("customerId",),
                filter=SqlFilterCondition(
                    field="customerCode",
                    operator=SqlFilterOperator.NE,
                    value=None,
                ),
            ),
        )
    except ValueError:
        pass
    else:
        raise AssertionError("Expected ne null to fail")


def test_executes_only_provider_compiled_commands_through_read_executor() -> None:
    executor = _RecordingExecutor()
    dispatcher = SqlCatalogReadDispatcher(
        compiler=SqlServerReadCompiler(),
        executor=executor,
    )

    asyncio.run(
        dispatcher.read_item(
            catalog=_catalog(),
            selection=SqlItemSelection(
                object_id="sales.Customer",
                projected_fields=("customerId",),
                key={"customerId": 7},
            ),
            context=ReadExecutionContext(request_id="req-1"),
        )
    )

    assert len(executor.commands) == 1
    assert executor.commands[0].purpose is SqlReadCommandPurpose.ITEM
    assert "FROM [sales].[Customer]" in executor.commands[0].sql
    assert executor.contexts[0].request_id == "req-1"


def test_normalizes_row_sets_from_generic_row_maps_deterministically() -> None:
    row_set = RowSet.normalize(
        (
            {"customerId": 1, "customerCode": "A"},
            {"customerId": 2, "customerCode": "B"},
        )
    )

    assert row_set.row_count == 2
    assert row_set.rows == (
        {"customerCode": "A", "customerId": 1},
        {"customerCode": "B", "customerId": 2},
    )


def _catalog() -> GraphqlCatalog:
    return GraphqlCatalog(
        catalog_version="1.0.0",
        provider=GraphqlCatalogProvider(
            kind="sql",
            engine="sqlserver",
            provider_version="0.4.7-test",
        ),
        build=GraphqlCatalogBuild(
            mode=GraphqlCatalogBuildMode.RUNTIME,
            source_root="db/src",
            source_digest="test-digest",
        ),
        objects=(
            GraphqlPublishedObject(
                id="sales.Customer",
                kind=PhysicalObjectKind.TABLE,
                readonly=True,
                source=GraphqlCatalogSource(schema_name="sales", object_name="Customer"),
                graphql=GraphqlCatalogGraphqlNames(
                    type_name="CustomerRecord",
                    collection_field="customerRecordList",
                    item_field="customerRecord",
                ),
                identity=GraphqlCatalogIdentity(
                    mode=GraphqlCatalogIdentityMode.SINGLE,
                    fields=("CustomerId",),
                    origin=GraphqlCatalogOrigin.INFERRED,
                ),
                fields=(
                    GraphqlCatalogField(
                        column="CustomerCode",
                        public_name="customerCode",
                        type="String",
                        nullable=False,
                        visibility=GraphqlCatalogFieldVisibility.PUBLIC,
                        filterable=True,
                        sortable=True,
                        sensitive=False,
                        origin=GraphqlCatalogOrigin.INFERRED,
                    ),
                    GraphqlCatalogField(
                        column="CustomerId",
                        public_name="customerId",
                        type="Int",
                        nullable=False,
                        visibility=GraphqlCatalogFieldVisibility.PUBLIC,
                        filterable=True,
                        sortable=True,
                        sensitive=False,
                        origin=GraphqlCatalogOrigin.INFERRED,
                    ),
                    GraphqlCatalogField(
                        column="IsActive",
                        public_name="isActive",
                        type="Boolean",
                        nullable=False,
                        visibility=GraphqlCatalogFieldVisibility.PUBLIC,
                        filterable=True,
                        sortable=False,
                        sensitive=False,
                        origin=GraphqlCatalogOrigin.INFERRED,
                    ),
                ),
                relations=(),
                capabilities=GraphqlCatalogCapabilities(
                    item=True,
                    collection=True,
                    filter=True,
                    sort=True,
                    pagination=GraphqlCatalogPagination(
                        mode=GraphqlCatalogPaginationMode.OFFSET,
                        default_limit=25,
                        max_limit=100,
                    ),
                ),
            ),
            GraphqlPublishedObject(
                id="sales.Order",
                kind=PhysicalObjectKind.TABLE,
                readonly=True,
                source=GraphqlCatalogSource(schema_name="sales", object_name="Order"),
                graphql=GraphqlCatalogGraphqlNames(
                    type_name="OrderRecord",
                    collection_field="orderRecordList",
                    item_field="orderRecord",
                ),
                identity=GraphqlCatalogIdentity(
                    mode=GraphqlCatalogIdentityMode.SINGLE,
                    fields=("OrderId",),
                    origin=GraphqlCatalogOrigin.INFERRED,
                ),
                fields=(
                    GraphqlCatalogField(
                        column="OrderId",
                        public_name="orderId",
                        type="Int",
                        nullable=False,
                        visibility=GraphqlCatalogFieldVisibility.PUBLIC,
                        filterable=True,
                        sortable=True,
                        sensitive=False,
                        origin=GraphqlCatalogOrigin.INFERRED,
                    ),
                    GraphqlCatalogField(
                        column="CustomerId",
                        public_name="customerId",
                        type="Int",
                        nullable=False,
                        visibility=GraphqlCatalogFieldVisibility.PUBLIC,
                        filterable=True,
                        sortable=True,
                        sensitive=False,
                        origin=GraphqlCatalogOrigin.INFERRED,
                    ),
                ),
                relations=(
                    GraphqlCatalogRelation(
                        name="customer",
                        target="sales.Customer",
                        cardinality=GraphqlCatalogRelationCardinality.ONE,
                        source_fields=("CustomerId",),
                        target_fields=("CustomerId",),
                        origin=GraphqlCatalogOrigin.INFERRED,
                    ),
                ),
                capabilities=GraphqlCatalogCapabilities(
                    item=True,
                    collection=True,
                    filter=True,
                    sort=True,
                    pagination=GraphqlCatalogPagination(
                        mode=GraphqlCatalogPaginationMode.OFFSET,
                        default_limit=25,
                        max_limit=100,
                    ),
                ),
            ),
        ),
        diagnostics=(),
    )


class _RecordingExecutor(ReadExecutor):
    def __init__(self) -> None:
        self.commands: list[SqlReadCommand] = []
        self.contexts: list[ReadExecutionContext] = []

    async def execute(self, command: SqlReadCommand, context: ReadExecutionContext) -> RowSet:
        self.commands.append(command)
        self.contexts.append(context)
        return RowSet(rows=(), row_count=0)

    async def close(self) -> None:
        return None