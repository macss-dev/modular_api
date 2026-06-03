import 'package:modular_api/src/graphql/catalog/graphql_catalog_builder.dart';
import 'package:modular_api/src/graphql/schema/graphql_schema_sdl_generator.dart';
import 'package:modular_api/src/graphql/sqlserver/physical_model.dart';
import 'package:test/test.dart';

void main() {
  group('GraphqlSchemaSdlGenerator', () {
    test('generates deterministic SDL for query, key, filter, order, and pagination contracts', () {
      const generator = GraphqlSchemaSdlGenerator();

      final sdl = generator.generate(_catalog());

      expect(sdl.trim(), equals(_expectedSdl.trim()));
    });

    test('omits singular fields for collection-only objects and excludes unsupported v1 filter operators', () {
      const generator = GraphqlSchemaSdlGenerator();

      final sdl = generator.generate(_catalog());

      expect(sdl, contains('eventLogList('));
      expect(sdl, isNot(contains('eventLog(key:')));
      expect(sdl, isNot(contains('profileJson: JsonFilterInput')));
      expect(sdl, isNot(contains('notIn:')));
      expect(sdl, isNot(contains('between:')));
      expect(sdl, isNot(contains('regex:')));
      expect(sdl, isNot(contains('fullText:')));
      expect(sdl, isNot(contains('ilike:')));
    });

    test('uses public field names in composite key inputs and preserves identity order', () {
      const generator = GraphqlSchemaSdlGenerator();

      final sdl = generator.generate(_compositeKeyCatalog());

      expect(
        sdl,
        contains('''input CompositeRecordKeyInput {
  countryCode: String!
  customerCode: String!
}'''),
      );
    });

    test('emits Long, Float, Date, and Uuid filter inputs with the expected operator matrix', () {
      const generator = GraphqlSchemaSdlGenerator();

      final sdl = generator.generate(_scalarFamilyCatalog());

      expect(sdl, contains('input LongFilterInput {'));
      expect(sdl, contains('input FloatFilterInput {'));
      expect(sdl, contains('input DateFilterInput {'));
      expect(
        sdl,
        contains('''input UuidFilterInput {
  eq: Uuid
  ne: Uuid
  in: [Uuid!]
  isNull: Boolean
}'''),
      );
      expect(sdl, isNot(contains('lt: Uuid')));
      expect(sdl, isNot(contains('gte: Uuid')));
    });
  });
}

GraphqlCatalog _compositeKeyCatalog() {
  return GraphqlCatalog(
    catalogVersion: '1.0.0',
    provider: const GraphqlCatalogProvider(
      kind: 'sql',
      engine: 'sqlserver',
      providerVersion: '0.4.7-test',
    ),
    build: const GraphqlCatalogBuild(
      mode: GraphqlCatalogBuildMode.runtime,
      sourceRoot: 'db/src',
      sourceDigest: 'test-digest',
    ),
    objects: const <GraphqlPublishedObject>[
      GraphqlPublishedObject(
        id: 'sales.CompositeRecord',
        kind: PhysicalObjectKind.table,
        readonly: true,
        source: GraphqlCatalogSource(
          schemaName: 'sales',
          objectName: 'CompositeRecord',
        ),
        graphql: GraphqlCatalogGraphqlNames(
          typeName: 'CompositeRecord',
          collectionField: 'compositeRecordList',
          itemField: 'compositeRecord',
        ),
        identity: GraphqlCatalogIdentity(
          mode: GraphqlCatalogIdentityMode.composite,
          fields: <String>['CountryCode', 'CustomerCode'],
          origin: GraphqlCatalogOrigin.annotated,
        ),
        fields: <GraphqlCatalogField>[
          GraphqlCatalogField(
            column: 'CountryCode',
            publicName: 'countryCode',
            type: 'String',
            nullable: false,
            visibility: GraphqlCatalogFieldVisibility.public,
            filterable: true,
            sortable: true,
            sensitive: false,
            origin: GraphqlCatalogOrigin.annotated,
          ),
          GraphqlCatalogField(
            column: 'CustomerCode',
            publicName: 'customerCode',
            type: 'String',
            nullable: false,
            visibility: GraphqlCatalogFieldVisibility.public,
            filterable: true,
            sortable: true,
            sensitive: false,
            origin: GraphqlCatalogOrigin.annotated,
          ),
        ],
        relations: <GraphqlCatalogRelation>[],
        capabilities: GraphqlCatalogCapabilities(
          item: true,
          collection: true,
          filter: true,
          sort: true,
          pagination: GraphqlCatalogPagination(
            mode: GraphqlCatalogPaginationMode.offset,
            defaultLimit: 50,
            maxLimit: 200,
          ),
        ),
      ),
    ],
    diagnostics: const <GraphqlCatalogDiagnostic>[],
  );
}

GraphqlCatalog _scalarFamilyCatalog() {
  return GraphqlCatalog(
    catalogVersion: '1.0.0',
    provider: const GraphqlCatalogProvider(
      kind: 'sql',
      engine: 'sqlserver',
      providerVersion: '0.4.7-test',
    ),
    build: const GraphqlCatalogBuild(
      mode: GraphqlCatalogBuildMode.runtime,
      sourceRoot: 'db/src',
      sourceDigest: 'test-digest',
    ),
    objects: const <GraphqlPublishedObject>[
      GraphqlPublishedObject(
        id: 'sales.ScalarFamilies',
        kind: PhysicalObjectKind.table,
        readonly: true,
        source: GraphqlCatalogSource(
          schemaName: 'sales',
          objectName: 'ScalarFamilies',
        ),
        graphql: GraphqlCatalogGraphqlNames(
          typeName: 'ScalarFamilies',
          collectionField: 'scalarFamiliesList',
          itemField: 'scalarFamilies',
        ),
        identity: GraphqlCatalogIdentity(
          mode: GraphqlCatalogIdentityMode.single,
          fields: <String>['EntityId'],
          origin: GraphqlCatalogOrigin.inferred,
        ),
        fields: <GraphqlCatalogField>[
          GraphqlCatalogField(
            column: 'EntityId',
            publicName: 'entityId',
            type: 'Int',
            nullable: false,
            visibility: GraphqlCatalogFieldVisibility.public,
            filterable: true,
            sortable: true,
            sensitive: false,
            origin: GraphqlCatalogOrigin.inferred,
          ),
          GraphqlCatalogField(
            column: 'BigScore',
            publicName: 'bigScore',
            type: 'Long',
            nullable: true,
            visibility: GraphqlCatalogFieldVisibility.public,
            filterable: true,
            sortable: true,
            sensitive: false,
            origin: GraphqlCatalogOrigin.inferred,
          ),
          GraphqlCatalogField(
            column: 'Ratio',
            publicName: 'ratio',
            type: 'Float',
            nullable: true,
            visibility: GraphqlCatalogFieldVisibility.public,
            filterable: true,
            sortable: true,
            sensitive: false,
            origin: GraphqlCatalogOrigin.inferred,
          ),
          GraphqlCatalogField(
            column: 'BirthDate',
            publicName: 'birthDate',
            type: 'Date',
            nullable: true,
            visibility: GraphqlCatalogFieldVisibility.public,
            filterable: true,
            sortable: true,
            sensitive: false,
            origin: GraphqlCatalogOrigin.inferred,
          ),
          GraphqlCatalogField(
            column: 'ExternalId',
            publicName: 'externalId',
            type: 'Uuid',
            nullable: true,
            visibility: GraphqlCatalogFieldVisibility.public,
            filterable: true,
            sortable: true,
            sensitive: false,
            origin: GraphqlCatalogOrigin.inferred,
          ),
        ],
        relations: <GraphqlCatalogRelation>[],
        capabilities: GraphqlCatalogCapabilities(
          item: true,
          collection: true,
          filter: true,
          sort: true,
          pagination: GraphqlCatalogPagination(
            mode: GraphqlCatalogPaginationMode.offset,
            defaultLimit: 50,
            maxLimit: 200,
          ),
        ),
      ),
    ],
    diagnostics: const <GraphqlCatalogDiagnostic>[],
  );
}

GraphqlCatalog _catalog() {
  return GraphqlCatalog(
    catalogVersion: '1.0.0',
    provider: const GraphqlCatalogProvider(
      kind: 'sql',
      engine: 'sqlserver',
      providerVersion: '0.4.7-test',
    ),
    build: const GraphqlCatalogBuild(
      mode: GraphqlCatalogBuildMode.runtime,
      sourceRoot: 'db/src',
      sourceDigest: 'test-digest',
    ),
    objects: const <GraphqlPublishedObject>[
      GraphqlPublishedObject(
        id: 'sales.Customer',
        kind: PhysicalObjectKind.table,
        readonly: true,
        source: GraphqlCatalogSource(
          schemaName: 'sales',
          objectName: 'Customer',
        ),
        graphql: GraphqlCatalogGraphqlNames(
          typeName: 'CustomerRecord',
          collectionField: 'customerRecordList',
          itemField: 'customerRecord',
        ),
        identity: GraphqlCatalogIdentity(
          mode: GraphqlCatalogIdentityMode.single,
          fields: <String>['CustomerId'],
          origin: GraphqlCatalogOrigin.annotated,
        ),
        fields: <GraphqlCatalogField>[
          GraphqlCatalogField(
            column: 'CreatedAt',
            publicName: 'createdAt',
            type: 'DateTime',
            nullable: false,
            visibility: GraphqlCatalogFieldVisibility.public,
            filterable: true,
            sortable: true,
            sensitive: false,
            origin: GraphqlCatalogOrigin.inferred,
          ),
          GraphqlCatalogField(
            column: 'CustomerCode',
            publicName: 'customerCode',
            type: 'String',
            nullable: false,
            visibility: GraphqlCatalogFieldVisibility.public,
            filterable: true,
            sortable: true,
            sensitive: false,
            origin: GraphqlCatalogOrigin.annotated,
          ),
          GraphqlCatalogField(
            column: 'CustomerId',
            publicName: 'customerId',
            type: 'Int',
            nullable: false,
            visibility: GraphqlCatalogFieldVisibility.public,
            filterable: true,
            sortable: true,
            sensitive: false,
            origin: GraphqlCatalogOrigin.annotated,
          ),
          GraphqlCatalogField(
            column: 'IsActive',
            publicName: 'isActive',
            type: 'Boolean',
            nullable: false,
            visibility: GraphqlCatalogFieldVisibility.public,
            filterable: true,
            sortable: false,
            sensitive: false,
            origin: GraphqlCatalogOrigin.inferred,
          ),
          GraphqlCatalogField(
            column: 'ProfileJson',
            publicName: 'profileJson',
            type: 'Json',
            nullable: true,
            visibility: GraphqlCatalogFieldVisibility.public,
            filterable: false,
            sortable: false,
            sensitive: false,
            origin: GraphqlCatalogOrigin.inferred,
          ),
          GraphqlCatalogField(
            column: 'TotalAmount',
            publicName: 'totalAmount',
            type: 'Decimal',
            nullable: false,
            visibility: GraphqlCatalogFieldVisibility.public,
            filterable: true,
            sortable: true,
            sensitive: false,
            origin: GraphqlCatalogOrigin.inferred,
          ),
        ],
        relations: <GraphqlCatalogRelation>[],
        capabilities: GraphqlCatalogCapabilities(
          item: true,
          collection: true,
          filter: true,
          sort: true,
          pagination: GraphqlCatalogPagination(
            mode: GraphqlCatalogPaginationMode.offset,
            defaultLimit: 25,
            maxLimit: 100,
          ),
        ),
      ),
      GraphqlPublishedObject(
        id: 'sales.EventLog',
        kind: PhysicalObjectKind.table,
        readonly: true,
        source: GraphqlCatalogSource(
          schemaName: 'sales',
          objectName: 'EventLog',
        ),
        graphql: GraphqlCatalogGraphqlNames(
          typeName: 'EventLog',
          collectionField: 'eventLogList',
          itemField: null,
        ),
        identity: GraphqlCatalogIdentity(
          mode: GraphqlCatalogIdentityMode.none,
          fields: <String>[],
          origin: GraphqlCatalogOrigin.inferred,
        ),
        fields: <GraphqlCatalogField>[
          GraphqlCatalogField(
            column: 'CreatedAt',
            publicName: 'createdAt',
            type: 'DateTime',
            nullable: false,
            visibility: GraphqlCatalogFieldVisibility.public,
            filterable: true,
            sortable: true,
            sensitive: false,
            origin: GraphqlCatalogOrigin.inferred,
          ),
          GraphqlCatalogField(
            column: 'PayloadJson',
            publicName: 'payloadJson',
            type: 'Json',
            nullable: true,
            visibility: GraphqlCatalogFieldVisibility.public,
            filterable: false,
            sortable: false,
            sensitive: false,
            origin: GraphqlCatalogOrigin.inferred,
          ),
        ],
        relations: <GraphqlCatalogRelation>[],
        capabilities: GraphqlCatalogCapabilities(
          item: false,
          collection: true,
          filter: true,
          sort: true,
          pagination: GraphqlCatalogPagination(
            mode: GraphqlCatalogPaginationMode.offset,
            defaultLimit: 50,
            maxLimit: 200,
          ),
        ),
      ),
    ],
    diagnostics: const <GraphqlCatalogDiagnostic>[],
  );
}

const String _expectedSdl = '''
scalar DateTime
scalar Decimal
scalar Json

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
}

type CustomerRecord {
  createdAt: DateTime!
  customerCode: String!
  customerId: Int!
  isActive: Boolean!
  profileJson: Json
  totalAmount: Decimal!
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
  createdAt: DateTimeFilterInput
  customerCode: StringFilterInput
  customerId: IntFilterInput
  isActive: BooleanFilterInput
  totalAmount: DecimalFilterInput
}

input CustomerRecordOrderByInput {
  field: CustomerRecordOrderField!
  direction: SortDirection!
}

enum CustomerRecordOrderField {
  CREATED_AT
  CUSTOMER_CODE
  CUSTOMER_ID
  TOTAL_AMOUNT
}

type EventLog {
  createdAt: DateTime!
  payloadJson: Json
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

input BooleanFilterInput {
  eq: Boolean
  ne: Boolean
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

input StringFilterInput {
  eq: String
  ne: String
  in: [String!]
  contains: String
  startsWith: String
  endsWith: String
  isNull: Boolean
}

enum SortDirection {
  ASC
  DESC
}

input OffsetPageInput {
  limit: Int
  offset: Int
}
''';