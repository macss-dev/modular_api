import { describe, expect, it } from 'vitest';

import {
  GraphqlCatalogBuildMode,
  GraphqlCatalogBuilder,
  GraphqlCatalogIdentityMode,
  GraphqlCatalogNaming,
  GraphqlCatalogOrigin,
  GraphqlCatalogRelationCardinality,
  PhysicalObjectKind,
  type GraphqlMetadataFile,
  type GraphqlObjectMetadata,
  type PhysicalCatalog,
} from '../../src';

describe('GraphqlCatalogNaming', () => {
  it('tokenizes separators casing acronyms and digits deterministically', () => {
    expect(GraphqlCatalogNaming.typeNameForObjectName('vw_Retiro')).toBe('VwRetiro');
    expect(GraphqlCatalogNaming.typeNameForObjectName('retiro-evento')).toBe('RetiroEvento');
    expect(GraphqlCatalogNaming.typeNameForObjectName('retiro.evento final')).toBe('RetiroEventoFinal');
    expect(GraphqlCatalogNaming.publicFieldNameForColumn('URL_ARCHIVO')).toBe('urlArchivo');
    expect(GraphqlCatalogNaming.publicFieldNameForColumn('FechaIDCliente')).toBe('fechaIdCliente');
    expect(GraphqlCatalogNaming.publicFieldNameForColumn('cliente#maestro')).toBe('clienteMaestro');
    expect(GraphqlCatalogNaming.typeNameForObjectName('cliente2Detalle')).toBe('Cliente2Detalle');
  });
});

describe('GraphqlCatalogBuilder', () => {
  it('builds a governed catalog with deterministic names identities limits and ordering', () => {
    const catalog = builder().build({
      physicalCatalog: physicalCatalog(),
      metadata: metadata(),
    });

    expect(catalog.catalogVersion).toBe('1.0.0');
    expect(catalog.provider.kind).toBe('sql');
    expect(catalog.provider.engine).toBe('sqlserver');
    expect(catalog.build.mode).toBe(GraphqlCatalogBuildMode.Runtime);
    expect(catalog.objects.map((object) => object.id)).toEqual([
      'sales.Customer',
      'sales.EventLog',
      'sales.Order',
      'sales.vw_OrderSummary',
    ]);

    const customer = catalog.objects.find((object) => object.id === 'sales.Customer');
    expect(customer?.graphql.typeName).toBe('CustomerRecord');
    expect(customer?.graphql.itemField).toBe('customerRecord');
    expect(customer?.graphql.collectionField).toBe('customerRecordList');
    expect(customer?.identity.mode).toBe(GraphqlCatalogIdentityMode.Single);
    expect(customer?.identity.origin).toBe(GraphqlCatalogOrigin.Annotated);
    expect(customer?.identity.fields).toEqual(['CustomerId']);
    expect(customer?.fields.map((field) => field.publicName)).toEqual([
      'customerCode',
      'customerId',
      'urlArchivo',
    ]);
    expect(customer?.capabilities.item).toBe(true);
    expect(customer?.capabilities.collection).toBe(true);
    expect(customer?.capabilities.filter).toBe(true);
    expect(customer?.capabilities.sort).toBe(true);
    expect(customer?.capabilities.pagination.defaultLimit).toBe(25);
    expect(customer?.capabilities.pagination.maxLimit).toBe(100);

    const eventLog = catalog.objects.find((object) => object.id === 'sales.EventLog');
    expect(eventLog?.identity.mode).toBe(GraphqlCatalogIdentityMode.None);
    expect(eventLog?.graphql.itemField).toBeUndefined();
    expect(eventLog?.capabilities.item).toBe(false);
    expect(eventLog?.capabilities.collection).toBe(true);
    expect(eventLog?.capabilities.pagination.defaultLimit).toBe(50);
    expect(eventLog?.capabilities.pagination.maxLimit).toBe(200);

    const summary = catalog.objects.find((object) => object.id === 'sales.vw_OrderSummary');
    expect(summary?.graphql.typeName).toBe('OrderSummary');
    expect(summary?.graphql.itemField).toBe('orderSummary');
    expect(summary?.graphql.collectionField).toBe('orderSummaryList');
    expect(summary?.identity.mode).toBe(GraphqlCatalogIdentityMode.Single);
    expect(summary?.identity.origin).toBe(GraphqlCatalogOrigin.Annotated);
    expect(summary?.identity.fields).toEqual(['OrderId']);
    expect(summary?.relations).toHaveLength(1);
    expect(summary?.relations[0]?.name).toBe('customer');
    expect(summary?.relations[0]?.cardinality).toBe(GraphqlCatalogRelationCardinality.One);
    expect(summary?.relations[0]?.target).toBe('sales.Customer');
    expect(summary?.relations[0]?.sourceFields).toEqual(['CustomerId']);
    expect(summary?.relations[0]?.targetFields).toEqual(['CustomerId']);
    expect(summary?.relations[0]?.origin).toBe(GraphqlCatalogOrigin.Annotated);

    expect(catalog.diagnostics).toEqual([]);
    expect(catalog.build.sourceDigest).toBeTruthy();
  });

  it('emits duplicate_public_name when two fields derive the same public name', () => {
    const catalog = builder().build({
      physicalCatalog: {
        objects: [
          {
            id: 'sales.DuplicateNames',
            kind: PhysicalObjectKind.Table,
            schemaName: 'sales',
            objectName: 'DuplicateNames',
            identityFields: ['customer_id'],
            fields: [
              { column: 'customer_id', nativeType: 'int', nullable: false },
              { column: 'customer.id', nativeType: 'nvarchar(50)', nullable: false },
            ],
            relations: [],
          },
        ],
      },
      metadata: {
        version: 1,
        objects: {
          'sales.DuplicateNames': { publish: true, fields: {}, relations: [] },
        },
      },
    });

    expect(catalog.diagnostics).toHaveLength(1);
    expect(catalog.diagnostics[0]?.code).toBe('duplicate_public_name');
    expect(catalog.diagnostics[0]?.objectId).toBe('sales.DuplicateNames');
    expect(catalog.diagnostics[0]?.field).toBe('customerId');
  });

  it('emits view_missing_identity when a published view does not declare usable identity', () => {
    const catalog = builder().build({
      physicalCatalog: {
        objects: [
          {
            id: 'sales.vw_NoIdentity',
            kind: PhysicalObjectKind.View,
            schemaName: 'sales',
            objectName: 'vw_NoIdentity',
            identityFields: [],
            fields: [{ column: 'OrderId', nativeType: 'int', nullable: false }],
            relations: [],
          },
        ],
      },
      metadata: {
        version: 1,
        objects: {
          'sales.vw_NoIdentity': { publish: true, fields: {}, relations: [] },
        },
      },
    });

    const summary = catalog.objects[0];
    expect(summary?.identity.mode).toBe(GraphqlCatalogIdentityMode.None);
    expect(summary?.graphql.itemField).toBeUndefined();
    expect(summary?.capabilities.item).toBe(false);
    expect(catalog.diagnostics).toHaveLength(1);
    expect(catalog.diagnostics[0]?.code).toBe('view_missing_identity');
    expect(catalog.diagnostics[0]?.objectId).toBe('sales.vw_NoIdentity');
  });

  it('preserves semantic order for composite identity and relation key fields', () => {
    const catalog = builder().build({
      physicalCatalog: {
        objects: [
          {
            id: 'sales.CompositeTarget',
            kind: PhysicalObjectKind.Table,
            schemaName: 'sales',
            objectName: 'CompositeTarget',
            identityFields: ['CountryCode', 'CustomerCode'],
            fields: [
              { column: 'CountryCode', nativeType: 'nvarchar(2)', nullable: false },
              { column: 'CustomerCode', nativeType: 'nvarchar(50)', nullable: false },
            ],
            relations: [],
          },
          {
            id: 'sales.vw_CompositeSource',
            kind: PhysicalObjectKind.View,
            schemaName: 'sales',
            objectName: 'vw_CompositeSource',
            identityFields: [],
            fields: [
              { column: 'KeyB', nativeType: 'int', nullable: false },
              { column: 'KeyA', nativeType: 'int', nullable: false },
              { column: 'CountryCode', nativeType: 'nvarchar(2)', nullable: false },
              { column: 'CustomerCode', nativeType: 'nvarchar(50)', nullable: false },
            ],
            relations: [],
          },
        ],
      },
      metadata: {
        version: 1,
        objects: {
          'sales.CompositeTarget': { publish: true, fields: {}, relations: [] },
          'sales.vw_CompositeSource': {
            publish: true,
            key: ['KeyB', 'KeyA'],
            fields: {},
            relations: [
              {
                name: 'target',
                cardinality: 'to-one',
                target: 'sales.CompositeTarget',
                via: ['CountryCode', 'CustomerCode'],
              },
            ],
          },
        },
      },
    });

    const source = catalog.objects.find((object) => object.id === 'sales.vw_CompositeSource');
    expect(source?.identity.fields).toEqual(['KeyB', 'KeyA']);
    expect(source?.relations[0]?.sourceFields).toEqual(['CountryCode', 'CustomerCode']);
    expect(source?.relations[0]?.targetFields).toEqual(['CountryCode', 'CustomerCode']);
    expect(catalog.diagnostics).toEqual([]);
  });

  it('keeps sourceDigest stable across semantically identical input order and changes it on relevant input changes', () => {
    const first = builder().build({
      physicalCatalog: physicalCatalog(),
      metadata: metadata(),
    });
    const second = builder().build({
      physicalCatalog: {
        objects: [...physicalCatalog().objects].reverse(),
      },
      metadata: {
        version: metadata().version,
        defaultsLimit: metadata().defaultsLimit,
        objects: Object.fromEntries(Object.entries(metadata().objects).reverse()),
      },
    });
    const changed = builder().build({
      physicalCatalog: physicalCatalog(),
      metadata: {
        version: metadata().version,
        defaultsLimit: metadata().defaultsLimit,
        objects: Object.fromEntries(
          Object.entries(metadata().objects).map(([key, value]) => [
            key,
            key === 'sales.Customer' ? { ...value, name: 'CustomerRenamed' } : value,
          ]),
        ) as Record<string, GraphqlObjectMetadata>,
      },
    });

    expect(first.build.sourceDigest).toBe(second.build.sourceDigest);
    expect(first.build.sourceDigest).not.toBe(changed.build.sourceDigest);
  });
});

function builder(): GraphqlCatalogBuilder {
  return new GraphqlCatalogBuilder({
    providerVersion: '0.4.7-test',
    sourceRoot: 'db/src',
    buildMode: GraphqlCatalogBuildMode.Runtime,
    engine: 'sqlserver',
  });
}

function metadata(): GraphqlMetadataFile {
  return {
    version: 1,
    defaultsLimit: { defaultValue: 50, maxValue: 200 },
    objects: {
      'sales.Customer': {
        publish: true,
        name: 'CustomerRecord',
        key: ['CustomerId'],
        fields: {
          CustomerCode: { name: 'customerCode', hidden: false, sensitive: false, noFilter: false, noSort: false },
        },
        relations: [],
        limit: { defaultValue: 25, maxValue: 100 },
      },
      'sales.EventLog': {
        publish: true,
        fields: {},
        relations: [],
      },
      'sales.Order': {
        publish: true,
        fields: {},
        relations: [],
      },
      'sales.vw_OrderSummary': {
        publish: true,
        name: 'OrderSummary',
        key: ['OrderId'],
        fields: {},
        relations: [
          {
            name: 'customer',
            cardinality: 'to-one',
            target: 'sales.Customer',
            via: ['CustomerId'],
          },
        ],
      },
    },
  };
}

function physicalCatalog(): PhysicalCatalog {
  return {
    objects: [
      {
        id: 'sales.Order',
        kind: PhysicalObjectKind.Table,
        schemaName: 'sales',
        objectName: 'Order',
        identityFields: ['OrderId'],
        fields: [
          { column: 'OrderId', nativeType: 'int', nullable: false },
          { column: 'CustomerId', nativeType: 'int', nullable: false },
          { column: 'TotalAmount', nativeType: 'decimal(18,2)', nullable: false },
        ],
        relations: [
          {
            name: 'Customer',
            sourceObjectId: 'sales.Order',
            targetObjectId: 'sales.Customer',
            sourceFields: ['CustomerId'],
            targetFields: ['CustomerId'],
          },
        ],
      },
      {
        id: 'sales.Customer',
        kind: PhysicalObjectKind.Table,
        schemaName: 'sales',
        objectName: 'Customer',
        identityFields: ['CustomerId'],
        fields: [
          { column: 'CustomerId', nativeType: 'int', nullable: false },
          { column: 'CustomerCode', nativeType: 'nvarchar(50)', nullable: false },
          { column: 'URLArchivo', nativeType: 'nvarchar(255)', nullable: true },
        ],
        relations: [],
      },
      {
        id: 'sales.vw_OrderSummary',
        kind: PhysicalObjectKind.View,
        schemaName: 'sales',
        objectName: 'vw_OrderSummary',
        identityFields: [],
        fields: [
          { column: 'OrderId', nativeType: 'int', nullable: false },
          { column: 'CustomerId', nativeType: 'int', nullable: false },
          { column: 'HasNotes', nativeType: 'bit', nullable: true },
        ],
        relations: [],
      },
      {
        id: 'sales.EventLog',
        kind: PhysicalObjectKind.Table,
        schemaName: 'sales',
        objectName: 'EventLog',
        identityFields: [],
        fields: [
          { column: 'CreatedAt', nativeType: 'datetime2', nullable: false },
          { column: 'PayloadJson', nativeType: 'nvarchar(max)', nullable: true },
        ],
        relations: [],
      },
    ],
  };
}