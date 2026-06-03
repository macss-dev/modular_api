import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import sql from 'mssql';

const sqlServerConfig: sql.config = {
  user: process.env.MODULAR_API_SQLSERVER_USERNAME ?? 'sa',
  password: process.env.MODULAR_API_SQLSERVER_PASSWORD ?? 'ModularApi_dev_StrongPass1',
  server: process.env.MODULAR_API_SQLSERVER_HOST ?? '127.0.0.1',
  port: Number.parseInt(process.env.MODULAR_API_SQLSERVER_PORT ?? '14333', 10),
  database: process.env.MODULAR_API_SQLSERVER_DATABASE ?? 'modular_api_graphql_v1',
  options: {
    encrypt: false,
    trustServerCertificate: true,
  },
};

describe('SQL Server Stage 1 smoke', () => {
  let pool: sql.ConnectionPool;

  beforeAll(async () => {
    pool = await sql.connect(sqlServerConfig);
  });

  afterAll(async () => {
    await pool.close();
  });

  it('reads the shared fixture objects and relation metadata', async () => {
    const objects = await pool.request().query<{
      schema_name: string;
      object_name: string;
      object_kind: string;
    }>(`
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
    `);

    expect(objects.recordset).toEqual(
      expect.arrayContaining([
        { schema_name: 'sales', object_name: 'Customer', object_kind: 'table' },
        { schema_name: 'sales', object_name: 'Order', object_kind: 'table' },
        { schema_name: 'sales', object_name: 'vw_OrderSummary', object_kind: 'view' },
      ]),
    );

    const primaryKey = await pool.request().query<{ column_name: string }>(`
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
    `);

    expect(primaryKey.recordset.map((row) => row.column_name)).toEqual(['CustomerId']);

    const relations = await pool.request().query<{
      source_object_name: string;
      source_column_name: string;
      target_object_name: string;
      target_column_name: string;
    }>(`
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
    `);

    expect(relations.recordset).toEqual([
      {
        source_object_name: 'Order',
        source_column_name: 'CustomerId',
        target_object_name: 'Customer',
        target_column_name: 'CustomerId',
      },
    ]);

    const viewColumns = await pool.request().query<{ column_name: string }>(`
      SELECT c.name AS column_name
      FROM sys.columns AS c
      WHERE c.object_id = OBJECT_ID(N'sales.vw_OrderSummary')
      ORDER BY c.column_id;
    `);

    expect(viewColumns.recordset.map((row) => row.column_name)).toEqual([
      'OrderId',
      'CustomerId',
      'CustomerCode',
      'FullName',
      'TotalAmount',
      'HasNotes',
      'CreatedAt',
    ]);
  });
});