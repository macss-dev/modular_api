"""GraphQL SDL generator tests for Stage 4 schema generation."""

from __future__ import annotations

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
    GraphqlSchemaSdlGenerator,
)
from modular_api.graphql.sqlserver import PhysicalObjectKind


def test_generates_stable_sdl_for_key_inputs_list_envelopes_filters_order_inputs_and_shared_offset_pagination() -> None:
    sdl = GraphqlSchemaSdlGenerator().generate(_catalog_fixture())

    assert sdl == """scalar Date
scalar DateTime
scalar Decimal
scalar Json
scalar Long
scalar Uuid

type Query {
  customerRecord(key: CustomerRecordKeyInput!): CustomerRecord
  customerRecordList(
    filter: CustomerRecordFilterInput
    orderBy: [CustomerRecordOrderByInput!]
    page: OffsetPageInput
  ): CustomerRecordList!
  eventLogList(
    filter: EventLogFilterInput
    orderBy: [EventLogOrderByInput!]
    page: OffsetPageInput
  ): EventLogList!
  orderLine(key: OrderLineKeyInput!): OrderLine
  orderLineList(
    filter: OrderLineFilterInput
    orderBy: [OrderLineOrderByInput!]
    page: OffsetPageInput
  ): OrderLineList!
}

type CustomerRecord {
  customerId: Int!
  customerName: String!
  balance: Decimal
  birthDate: Date
  createdAt: DateTime!
  isActive: Boolean
  externalId: Uuid!
  version: Long!
  payload: Json
  orderLines: [OrderLine!]!
}

type CustomerRecordList {
  items: [CustomerRecord!]!
  totalCount: Int!
}

input CustomerRecordKeyInput {
  customerId: Int!
}

input CustomerRecordFilterInput {
  and: [CustomerRecordFilterInput!]
  or: [CustomerRecordFilterInput!]
  not: CustomerRecordFilterInput
  customerId: IntFilterInput
  customerName: StringFilterInput
  balance: DecimalFilterInput
  birthDate: DateFilterInput
  createdAt: DateTimeFilterInput
  isActive: BooleanFilterInput
  externalId: UuidFilterInput
  version: LongFilterInput
}

input CustomerRecordOrderByInput {
  field: CustomerRecordOrderField!
  direction: SortDirection!
}

enum CustomerRecordOrderField {
  CUSTOMER_ID
  CUSTOMER_NAME
  BALANCE
  BIRTH_DATE
  CREATED_AT
  IS_ACTIVE
  EXTERNAL_ID
  VERSION
}

type EventLog {
  createdAt: DateTime!
  payload: Json
}

type EventLogList {
  items: [EventLog!]!
  totalCount: Int!
}

input EventLogFilterInput {
  and: [EventLogFilterInput!]
  or: [EventLogFilterInput!]
  not: EventLogFilterInput
  createdAt: DateTimeFilterInput
}

input EventLogOrderByInput {
  field: EventLogOrderField!
  direction: SortDirection!
}

enum EventLogOrderField {
  CREATED_AT
}

type OrderLine {
  orderId: Int!
  lineNumber: Int!
  sku: String!
  quantity: Int!
  customer: CustomerRecord
}

type OrderLineList {
  items: [OrderLine!]!
  totalCount: Int!
}

input OrderLineKeyInput {
  orderId: Int!
  lineNumber: Int!
}

input OrderLineFilterInput {
  and: [OrderLineFilterInput!]
  or: [OrderLineFilterInput!]
  not: OrderLineFilterInput
  orderId: IntFilterInput
  lineNumber: IntFilterInput
  sku: StringFilterInput
  quantity: IntFilterInput
}

input OrderLineOrderByInput {
  field: OrderLineOrderField!
  direction: SortDirection!
}

enum OrderLineOrderField {
  ORDER_ID
  LINE_NUMBER
  SKU
  QUANTITY
}

input BooleanFilterInput {
  eq: Boolean
  ne: Boolean
  isNull: Boolean
}

input DateFilterInput {
  eq: Date
  ne: Date
  in: [Date!]
  lt: Date
  lte: Date
  gt: Date
  gte: Date
  isNull: Boolean
}

input DateTimeFilterInput {
  eq: DateTime
  ne: DateTime
  in: [DateTime!]
  lt: DateTime
  lte: DateTime
  gt: DateTime
  gte: DateTime
  isNull: Boolean
}

input DecimalFilterInput {
  eq: Decimal
  ne: Decimal
  in: [Decimal!]
  lt: Decimal
  lte: Decimal
  gt: Decimal
  gte: Decimal
  isNull: Boolean
}

input IntFilterInput {
  eq: Int
  ne: Int
  in: [Int!]
  lt: Int
  lte: Int
  gt: Int
  gte: Int
  isNull: Boolean
}

input LongFilterInput {
  eq: Long
  ne: Long
  in: [Long!]
  lt: Long
  lte: Long
  gt: Long
  gte: Long
  isNull: Boolean
}

input StringFilterInput {
  eq: String
  ne: String
  in: [String!]
  contains: String
  startsWith: String
  endsWith: String
  isNull: Boolean
}

input UuidFilterInput {
  eq: Uuid
  ne: Uuid
  in: [Uuid!]
  isNull: Boolean
}

enum SortDirection {
  ASC
  DESC
}

input OffsetPageInput {
  limit: Int
  offset: Int
}"""


def test_omits_disallowed_v1_operators_and_json_scalar_filter_inputs() -> None:
    sdl = GraphqlSchemaSdlGenerator().generate(_catalog_fixture())

    assert "payload: JsonFilterInput" not in sdl
    assert "input JsonFilterInput" not in sdl
    assert "notIn" not in sdl
    assert "between" not in sdl
    assert "regex" not in sdl
    assert "fullText" not in sdl
    assert "icontains" not in sdl


def _catalog_fixture() -> GraphqlCatalog:
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
            source_digest="digest",
        ),
        objects=(
            GraphqlPublishedObject(
                id="sales.Customer",
                kind=PhysicalObjectKind.TABLE,
                readonly=True,
                source=GraphqlCatalogSource(schema_name="sales", object_name="Customer"),
                graphql=GraphqlCatalogGraphqlNames(
                    type_name="CustomerRecord",
                    item_field="customerRecord",
                    collection_field="customerRecordList",
                ),
                identity=GraphqlCatalogIdentity(
                    mode=GraphqlCatalogIdentityMode.SINGLE,
                    fields=("CustomerId",),
                    origin=GraphqlCatalogOrigin.ANNOTATED,
                ),
                fields=(
                    _field("CustomerId", "customerId", "Int", False),
                    _field("CustomerName", "customerName", "String", False),
                    _field("Balance", "balance", "Decimal", True),
                    _field("BirthDate", "birthDate", "Date", True),
                    _field("CreatedAt", "createdAt", "DateTime", False),
                    _field("IsActive", "isActive", "Boolean", True),
                    _field("ExternalId", "externalId", "Uuid", False),
                    _field("Version", "version", "Long", False),
                    _field("Payload", "payload", "Json", True, filterable=False, sortable=False),
                ),
                relations=(
                    GraphqlCatalogRelation(
                        name="orderLines",
                        target="sales.OrderLine",
                        cardinality=GraphqlCatalogRelationCardinality.MANY,
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
            GraphqlPublishedObject(
                id="sales.EventLog",
                kind=PhysicalObjectKind.TABLE,
                readonly=True,
                source=GraphqlCatalogSource(schema_name="sales", object_name="EventLog"),
                graphql=GraphqlCatalogGraphqlNames(
                    type_name="EventLog",
                    item_field=None,
                    collection_field="eventLogList",
                ),
                identity=GraphqlCatalogIdentity(
                    mode=GraphqlCatalogIdentityMode.NONE,
                    fields=(),
                    origin=GraphqlCatalogOrigin.INFERRED,
                ),
                fields=(
                    _field("CreatedAt", "createdAt", "DateTime", False),
                    _field("Payload", "payload", "Json", True, filterable=False, sortable=False),
                ),
                relations=(),
                capabilities=GraphqlCatalogCapabilities(
                    item=False,
                    collection=True,
                    filter=True,
                    sort=True,
                    pagination=GraphqlCatalogPagination(
                        mode=GraphqlCatalogPaginationMode.OFFSET,
                        default_limit=50,
                        max_limit=200,
                    ),
                ),
            ),
            GraphqlPublishedObject(
                id="sales.OrderLine",
                kind=PhysicalObjectKind.TABLE,
                readonly=True,
                source=GraphqlCatalogSource(schema_name="sales", object_name="OrderLine"),
                graphql=GraphqlCatalogGraphqlNames(
                    type_name="OrderLine",
                    item_field="orderLine",
                    collection_field="orderLineList",
                ),
                identity=GraphqlCatalogIdentity(
                    mode=GraphqlCatalogIdentityMode.COMPOSITE,
                    fields=("OrderId", "LineNumber"),
                    origin=GraphqlCatalogOrigin.INFERRED,
                ),
                fields=(
                    _field("OrderId", "orderId", "Int", False),
                    _field("LineNumber", "lineNumber", "Int", False),
                    _field("Sku", "sku", "String", False),
                    _field("Quantity", "quantity", "Int", False),
                    _field(
                        "CustomerId",
                        "customerId",
                        "Int",
                        False,
                        visibility=GraphqlCatalogFieldVisibility.HIDDEN,
                        filterable=False,
                        sortable=False,
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
                        default_limit=50,
                        max_limit=200,
                    ),
                ),
            ),
        ),
        diagnostics=(),
    )


def _field(
    column: str,
    public_name: str,
    type_name: str,
    nullable: bool,
    *,
    visibility: GraphqlCatalogFieldVisibility = GraphqlCatalogFieldVisibility.PUBLIC,
    filterable: bool = True,
    sortable: bool = True,
) -> GraphqlCatalogField:
    return GraphqlCatalogField(
        column=column,
        public_name=public_name,
        type=type_name,
        nullable=nullable,
        visibility=visibility,
        filterable=filterable,
        sortable=sortable,
        sensitive=False,
        origin=GraphqlCatalogOrigin.INFERRED,
    )