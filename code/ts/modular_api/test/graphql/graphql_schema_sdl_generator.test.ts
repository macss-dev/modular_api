import { describe, expect, it } from 'vitest';

import {
  GraphqlCatalogBuildMode,
  GraphqlCatalogIdentityMode,
  GraphqlCatalogOrigin,
  GraphqlCatalogPaginationMode,
  GraphqlCatalogRelationCardinality,
  GraphqlSchemaSdlGenerator,
  PhysicalObjectKind,
  type GraphqlCatalog,
} from '../../src';

describe('GraphqlSchemaSdlGenerator', () => {
  it('generates stable SDL for key inputs list envelopes filters order inputs and shared offset pagination', () => {
    const sdl = new GraphqlSchemaSdlGenerator().generate(catalogFixture());

    expect(sdl).toBe(`scalar Date
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
}`);
  });

  it('omits disallowed v1 operators and json scalar filter inputs', () => {
    const sdl = new GraphqlSchemaSdlGenerator().generate(catalogFixture());

    expect(sdl).not.toContain('payload: JsonFilterInput');
    expect(sdl).not.toContain('input JsonFilterInput');
    expect(sdl).not.toContain('notIn');
    expect(sdl).not.toContain('between');
    expect(sdl).not.toContain('regex');
    expect(sdl).not.toContain('fullText');
    expect(sdl).not.toContain('icontains');
  });
});

function catalogFixture(): GraphqlCatalog {
  return {
    catalogVersion: '1.0.0',
    provider: {
      kind: 'sql',
      engine: 'sqlserver',
      providerVersion: '0.4.7-test',
    },
    build: {
      mode: GraphqlCatalogBuildMode.Runtime,
      sourceRoot: 'db/src',
      sourceDigest: 'digest',
    },
    objects: [
      {
        id: 'sales.Customer',
        kind: PhysicalObjectKind.Table,
        readonly: true,
        source: {
          schemaName: 'sales',
          objectName: 'Customer',
        },
        graphql: {
          typeName: 'CustomerRecord',
          itemField: 'customerRecord',
          collectionField: 'customerRecordList',
        },
        identity: {
          mode: GraphqlCatalogIdentityMode.Single,
          fields: ['CustomerId'],
          origin: GraphqlCatalogOrigin.Annotated,
        },
        fields: [
          field('CustomerId', 'customerId', 'Int', false),
          field('CustomerName', 'customerName', 'String', false),
          field('Balance', 'balance', 'Decimal', true),
          field('BirthDate', 'birthDate', 'Date', true),
          field('CreatedAt', 'createdAt', 'DateTime', false),
          field('IsActive', 'isActive', 'Boolean', true),
          field('ExternalId', 'externalId', 'Uuid', false),
          field('Version', 'version', 'Long', false),
          field('Payload', 'payload', 'Json', true, {
            filterable: false,
            sortable: false,
          }),
        ],
        relations: [
          {
            name: 'orderLines',
            target: 'sales.OrderLine',
            cardinality: GraphqlCatalogRelationCardinality.Many,
            sourceFields: ['CustomerId'],
            targetFields: ['CustomerId'],
            origin: GraphqlCatalogOrigin.Inferred,
          },
        ],
        capabilities: {
          item: true,
          collection: true,
          filter: true,
          sort: true,
          pagination: {
            mode: GraphqlCatalogPaginationMode.Offset,
            defaultLimit: 25,
            maxLimit: 100,
          },
        },
      },
      {
        id: 'sales.EventLog',
        kind: PhysicalObjectKind.Table,
        readonly: true,
        source: {
          schemaName: 'sales',
          objectName: 'EventLog',
        },
        graphql: {
          typeName: 'EventLog',
          collectionField: 'eventLogList',
        },
        identity: {
          mode: GraphqlCatalogIdentityMode.None,
          fields: [],
          origin: GraphqlCatalogOrigin.Inferred,
        },
        fields: [
          field('CreatedAt', 'createdAt', 'DateTime', false),
          field('Payload', 'payload', 'Json', true, {
            filterable: false,
            sortable: false,
          }),
        ],
        relations: [],
        capabilities: {
          item: false,
          collection: true,
          filter: true,
          sort: true,
          pagination: {
            mode: GraphqlCatalogPaginationMode.Offset,
            defaultLimit: 50,
            maxLimit: 200,
          },
        },
      },
      {
        id: 'sales.OrderLine',
        kind: PhysicalObjectKind.Table,
        readonly: true,
        source: {
          schemaName: 'sales',
          objectName: 'OrderLine',
        },
        graphql: {
          typeName: 'OrderLine',
          itemField: 'orderLine',
          collectionField: 'orderLineList',
        },
        identity: {
          mode: GraphqlCatalogIdentityMode.Composite,
          fields: ['OrderId', 'LineNumber'],
          origin: GraphqlCatalogOrigin.Inferred,
        },
        fields: [
          field('OrderId', 'orderId', 'Int', false),
          field('LineNumber', 'lineNumber', 'Int', false),
          field('Sku', 'sku', 'String', false),
          field('Quantity', 'quantity', 'Int', false),
          field('CustomerId', 'customerId', 'Int', false, {
            visibility: 'hidden',
            filterable: false,
            sortable: false,
          }),
        ],
        relations: [
          {
            name: 'customer',
            target: 'sales.Customer',
            cardinality: GraphqlCatalogRelationCardinality.One,
            sourceFields: ['CustomerId'],
            targetFields: ['CustomerId'],
            origin: GraphqlCatalogOrigin.Inferred,
          },
        ],
        capabilities: {
          item: true,
          collection: true,
          filter: true,
          sort: true,
          pagination: {
            mode: GraphqlCatalogPaginationMode.Offset,
            defaultLimit: 50,
            maxLimit: 200,
          },
        },
      },
    ],
    diagnostics: [],
  };
}

function field(
  column: string,
  publicName: string,
  type: string,
  nullable: boolean,
  overrides?: {
    visibility?: 'public' | 'hidden';
    filterable?: boolean;
    sortable?: boolean;
  },
) {
  return {
    column,
    publicName,
    type,
    nullable,
    visibility: overrides?.visibility ?? 'public',
    filterable: overrides?.filterable ?? true,
    sortable: overrides?.sortable ?? true,
    sensitive: false,
    origin: GraphqlCatalogOrigin.Inferred,
  } as const;
}