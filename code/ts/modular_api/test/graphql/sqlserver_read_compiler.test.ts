import { describe, expect, it } from 'vitest';

import {
  GraphqlCatalogBuildMode,
  GraphqlCatalogFieldVisibility,
  GraphqlCatalogIdentityMode,
  GraphqlCatalogOrigin,
  GraphqlCatalogPaginationMode,
  GraphqlCatalogRelationCardinality,
  PhysicalObjectKind,
  ReadExecutionContext,
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
  SqlReadCommandPurpose,
  SqlRelationBatchSelection,
  SqlServerReadCompiler,
  SqlSortDirection,
  type GraphqlCatalog,
  type ReadExecutor,
  type SqlReadCommand,
} from '../../src';

describe('SqlServerReadCompiler', () => {
  const compiler = new SqlServerReadCompiler();

  it('item query compiles to purpose item', () => {
    const command = compiler.compileItem({
      catalog: catalogFixture(),
      selection: new SqlItemSelection({
        objectId: 'sales.Customer',
        projectedFields: ['customerId', 'customerCode'],
        key: { customerId: 42 },
      }),
    });

    expect(command.engine).toBe('sqlserver');
    expect(command.purpose).toBe(SqlReadCommandPurpose.Item);
    expect(command.sql).toContain('SELECT TOP (1)');
    expect(command.sql).toContain('FROM [sales].[Customer]');
    expect(command.sql).toContain('WHERE [CustomerId] = @p0');
    expect(command.parameters).toHaveLength(1);
    expect(command.parameters[0]?.name).toBe('p0');
    expect(command.parameters[0]?.value).toBe(42);
  });

  it('collection query compiles to purpose collection and keeps string semantics engine-native', () => {
    const command = compiler.compileCollection({
      catalog: catalogFixture(),
      selection: new SqlCollectionSelection({
        objectId: 'sales.Customer',
        projectedFields: ['customerId', 'customerCode', 'isActive'],
        filter: SqlFilterGroup.and([
          new SqlFilterCondition({
            field: 'customerCode',
            operator: SqlFilterOperator.Contains,
            value: 'ACME',
          }),
          new SqlFilterCondition({
            field: 'isActive',
            operator: SqlFilterOperator.Eq,
            value: true,
          }),
        ]),
        orderBy: [
          new SqlOrderByClause({ field: 'customerCode', direction: SqlSortDirection.Asc }),
          new SqlOrderByClause({ field: 'customerId', direction: SqlSortDirection.Desc }),
        ],
        page: new SqlPage({ limit: 25, offset: 50 }),
      }),
    });

    expect(command.purpose).toBe(SqlReadCommandPurpose.Collection);
    expect(command.sql).toContain('FROM [sales].[Customer]');
    expect(command.sql).toContain('[CustomerCode] LIKE');
    expect(command.sql).toContain('ORDER BY [CustomerCode] ASC, [CustomerId] DESC');
    expect(command.sql).toContain('OFFSET @p2 ROWS FETCH NEXT @p3 ROWS ONLY');
    expect(command.sql).not.toContain('LOWER(');
    expect(command.parameters.map((parameter) => parameter.value)).toEqual(['ACME', true, 50, 25]);
  });

  it('totalCount query compiles to purpose count', () => {
    const command = compiler.compileCount({
      catalog: catalogFixture(),
      selection: new SqlCountSelection({
        objectId: 'sales.Customer',
        filter: new SqlFilterCondition({
          field: 'isActive',
          operator: SqlFilterOperator.Eq,
          value: true,
        }),
      }),
    });

    expect(command.purpose).toBe(SqlReadCommandPurpose.Count);
    expect(command.sql).toContain('SELECT COUNT_BIG(1) AS [totalCount]');
    expect(command.sql).toContain('WHERE [IsActive] = @p0');
    expect(command.parameters[0]?.value).toBe(true);
  });

  it('relation batching compiles to purpose relation-batch', () => {
    const command = compiler.compileRelationBatch({
      catalog: catalogFixture(),
      selection: new SqlRelationBatchSelection({
        sourceObjectId: 'sales.Order',
        relationName: 'customer',
        projectedFields: ['customerId', 'customerCode'],
        parentKeys: [{ customerId: 1 }, { customerId: 2 }],
      }),
    });

    expect(command.purpose).toBe(SqlReadCommandPurpose.RelationBatch);
    expect(command.sql).toContain('FROM [sales].[Customer]');
    expect(command.sql).toContain('WHERE [CustomerId] IN (@p0, @p1)');
    expect(command.parameters.map((parameter) => parameter.value)).toEqual([1, 2]);
  });

  it('eq null and ne null are rejected in favor of isNull', () => {
    expect(() =>
      compiler.compileCollection({
        catalog: catalogFixture(),
        selection: new SqlCollectionSelection({
          objectId: 'sales.Customer',
          projectedFields: ['customerId'],
          filter: new SqlFilterCondition({
            field: 'customerCode',
            operator: SqlFilterOperator.Eq,
            value: null,
          }),
        }),
      }),
    ).toThrowError();

    expect(() =>
      compiler.compileCollection({
        catalog: catalogFixture(),
        selection: new SqlCollectionSelection({
          objectId: 'sales.Customer',
          projectedFields: ['customerId'],
          filter: new SqlFilterCondition({
            field: 'customerCode',
            operator: SqlFilterOperator.Ne,
            value: null,
          }),
        }),
      }),
    ).toThrowError();
  });
});

describe('SqlCatalogReadDispatcher', () => {
  it('executes only provider-compiled commands through ReadExecutor', async () => {
    const executor = new RecordingExecutor();
    const dispatcher = new SqlCatalogReadDispatcher({
      compiler: new SqlServerReadCompiler(),
      executor,
    });

    await dispatcher.readItem({
      catalog: catalogFixture(),
      selection: new SqlItemSelection({
        objectId: 'sales.Customer',
        projectedFields: ['customerId'],
        key: { customerId: 7 },
      }),
      context: new ReadExecutionContext({ requestId: 'req-1' }),
    });

    expect(executor.commands).toHaveLength(1);
    expect(executor.commands[0]?.purpose).toBe(SqlReadCommandPurpose.Item);
    expect(executor.commands[0]?.sql).toContain('FROM [sales].[Customer]');
    expect(executor.contexts[0]?.requestId).toBe('req-1');
  });

  it('normalizes row sets from generic row maps deterministically', () => {
    const rowSet = RowSet.normalize([
      { customerId: 1, customerCode: 'A' } as Record<PropertyKey, unknown>,
      { customerId: 2, customerCode: 'B' } as Record<PropertyKey, unknown>,
    ]);

    expect(rowSet.rowCount).toBe(2);
    expect(rowSet.rows).toEqual([
      { customerCode: 'A', customerId: 1 },
      { customerCode: 'B', customerId: 2 },
    ]);
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
      sourceDigest: 'test-digest',
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
          collectionField: 'customerRecordList',
          itemField: 'customerRecord',
        },
        identity: {
          mode: GraphqlCatalogIdentityMode.Single,
          fields: ['CustomerId'],
          origin: GraphqlCatalogOrigin.Inferred,
        },
        fields: [
          {
            column: 'CustomerCode',
            publicName: 'customerCode',
            type: 'String',
            nullable: false,
            visibility: GraphqlCatalogFieldVisibility.Public,
            filterable: true,
            sortable: true,
            sensitive: false,
            origin: GraphqlCatalogOrigin.Inferred,
          },
          {
            column: 'CustomerId',
            publicName: 'customerId',
            type: 'Int',
            nullable: false,
            visibility: GraphqlCatalogFieldVisibility.Public,
            filterable: true,
            sortable: true,
            sensitive: false,
            origin: GraphqlCatalogOrigin.Inferred,
          },
          {
            column: 'IsActive',
            publicName: 'isActive',
            type: 'Boolean',
            nullable: false,
            visibility: GraphqlCatalogFieldVisibility.Public,
            filterable: true,
            sortable: false,
            sensitive: false,
            origin: GraphqlCatalogOrigin.Inferred,
          },
        ],
        relations: [],
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
        id: 'sales.Order',
        kind: PhysicalObjectKind.Table,
        readonly: true,
        source: {
          schemaName: 'sales',
          objectName: 'Order',
        },
        graphql: {
          typeName: 'OrderRecord',
          collectionField: 'orderRecordList',
          itemField: 'orderRecord',
        },
        identity: {
          mode: GraphqlCatalogIdentityMode.Single,
          fields: ['OrderId'],
          origin: GraphqlCatalogOrigin.Inferred,
        },
        fields: [
          {
            column: 'OrderId',
            publicName: 'orderId',
            type: 'Int',
            nullable: false,
            visibility: GraphqlCatalogFieldVisibility.Public,
            filterable: true,
            sortable: true,
            sensitive: false,
            origin: GraphqlCatalogOrigin.Inferred,
          },
          {
            column: 'CustomerId',
            publicName: 'customerId',
            type: 'Int',
            nullable: false,
            visibility: GraphqlCatalogFieldVisibility.Public,
            filterable: true,
            sortable: true,
            sensitive: false,
            origin: GraphqlCatalogOrigin.Inferred,
          },
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
            defaultLimit: 25,
            maxLimit: 100,
          },
        },
      },
    ],
    diagnostics: [],
  };
}

class RecordingExecutor implements ReadExecutor {
  readonly commands: SqlReadCommand[] = [];
  readonly contexts: ReadExecutionContext[] = [];

  async execute(command: SqlReadCommand, context: ReadExecutionContext): Promise<RowSet> {
    this.commands.push(command);
    this.contexts.push(context);
    return new RowSet({ rows: [], rowCount: 0 });
  }

  async close(): Promise<void> {}
}