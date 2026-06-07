import { createRequire } from 'node:module';

import { describe, expect, it } from 'vitest';

import {
  PhysicalObjectKind,
  SqlServerConnectionSettings,
  SqlServerMetadataReader,
  type PhysicalCatalog,
  type PhysicalObject,
} from '../../src';

const require = createRequire(import.meta.url);
const hasSqlDriver = (() => {
  try {
    require.resolve('mssql');
    return true;
  } catch {
    return false;
  }
})();
const itWithDriver = hasSqlDriver ? it : it.skip;

describe('SqlServerMetadataReader smoke', () => {
  it('explains how to enable the optional mssql dependency when the driver is unavailable', async () => {
    const reader = new SqlServerMetadataReader({
      connection: new SqlServerConnectionSettings({
        host: '127.0.0.1',
        port: 14333,
        database: 'modular_api_graphql_v1',
        username: 'sa',
        password: 'ModularApi_dev_StrongPass1',
      }),
      sqlModuleLoader: () => {
        throw new Error("Cannot find module 'mssql'");
      },
    });

    await expect(reader.introspect()).rejects.toThrow(
      'SqlServerMetadataReader requires the optional "mssql" package. Install it to use SQL Server introspection.',
    );
  });

  itWithDriver(
    'returns table columns with normalized native types, primary keys, and foreign keys',
    async () => {
      const catalog = await introspectStage1Fixture();

      const customer = catalog.objects.find((object) => object.id === 'sales.Customer');
      expect(customer).toBeDefined();
      expect(customer?.kind).toBe(PhysicalObjectKind.Table);
      expect(customer?.identityFields).toEqual(['CustomerId']);
      expect(customer ? fieldSnapshot(customer) : null).toEqual([
        { column: 'CustomerId', nativeType: 'int', nullable: false },
        { column: 'CustomerCode', nativeType: 'nvarchar(20)', nullable: false },
        { column: 'FullName', nativeType: 'nvarchar(120)', nullable: false },
        { column: 'CreatedAt', nativeType: 'datetime2(7)', nullable: false },
        { column: 'IsActive', nativeType: 'bit', nullable: false },
      ]);

      const order = catalog.objects.find((object) => object.id === 'sales.Order');
      expect(order).toBeDefined();
      expect(order ? fieldSnapshot(order) : null).toEqual([
        { column: 'OrderId', nativeType: 'uniqueidentifier', nullable: false },
        { column: 'CustomerId', nativeType: 'int', nullable: false },
        { column: 'TotalAmount', nativeType: 'decimal(18,2)', nullable: false },
        { column: 'Notes', nativeType: 'nvarchar(200)', nullable: true },
        { column: 'CreatedAt', nativeType: 'datetime2(7)', nullable: false },
      ]);
      expect(order?.relations).toHaveLength(1);
      expect(order?.relations[0]).toEqual({
        name: 'FK_Order_Customer',
        sourceObjectId: 'sales.Order',
        targetObjectId: 'sales.Customer',
        sourceFields: ['CustomerId'],
        targetFields: ['CustomerId'],
      });
    },
    120_000,
  );

  itWithDriver(
    'returns view columns with projected native types and nullability from real metadata',
    async () => {
      const catalog = await introspectStage1Fixture();

      const summary = catalog.objects.find((object) => object.id === 'sales.vw_OrderSummary');
      expect(summary).toBeDefined();
      expect(summary?.kind).toBe(PhysicalObjectKind.View);
      expect(summary ? fieldSnapshot(summary) : null).toEqual([
        { column: 'OrderId', nativeType: 'uniqueidentifier', nullable: false },
        { column: 'CustomerId', nativeType: 'int', nullable: false },
        { column: 'CustomerCode', nativeType: 'nvarchar(20)', nullable: false },
        { column: 'FullName', nativeType: 'nvarchar(120)', nullable: false },
        { column: 'TotalAmount', nativeType: 'decimal(18,2)', nullable: false },
        { column: 'HasNotes', nativeType: 'bit', nullable: true },
        { column: 'CreatedAt', nativeType: 'datetime2(7)', nullable: false },
      ]);
      expect(summary?.identityFields).toEqual([]);
    },
    120_000,
  );

  itWithDriver(
    'is stable across repeated introspection of the same prepared database state',
    async () => {
      const first = await introspectStage1Fixture();
      const second = await introspectStage1Fixture();

      expect(catalogSnapshot(first)).toEqual(catalogSnapshot(second));
    },
    120_000,
  );

  itWithDriver(
    'keeps logical object identity without requiring file-path provenance',
    async () => {
      const catalog = await introspectStage1Fixture();
      const customer = catalog.objects.find((object) => object.id === 'sales.Customer');

      expect(customer).toBeDefined();
      expect(customer?.schemaName).toBe('sales');
      expect(customer?.objectName).toBe('Customer');
      expect(customer?.id).toBe('sales.Customer');
    },
    120_000,
  );
});

async function introspectStage1Fixture(): Promise<PhysicalCatalog> {
  const reader = new SqlServerMetadataReader({
    connection: SqlServerConnectionSettings.fromEnvironment(),
  });

  return reader.introspect({ schemaNames: ['sales'] });
}

function fieldSnapshot(object: PhysicalObject): Array<{ column: string; nativeType: string; nullable: boolean }> {
  return object.fields.map((field) => ({
    column: field.column,
    nativeType: field.nativeType,
    nullable: field.nullable,
  }));
}

function catalogSnapshot(catalog: PhysicalCatalog): Record<string, unknown> {
  return {
    objects: catalog.objects.map((object) => ({
      id: object.id,
      kind: object.kind,
      schemaName: object.schemaName,
      objectName: object.objectName,
      identityFields: object.identityFields,
      fields: fieldSnapshot(object),
      relations: object.relations.map((relation) => ({
        name: relation.name,
        sourceObjectId: relation.sourceObjectId,
        targetObjectId: relation.targetObjectId,
        sourceFields: relation.sourceFields,
        targetFields: relation.targetFields,
      })),
    })),
  };
}