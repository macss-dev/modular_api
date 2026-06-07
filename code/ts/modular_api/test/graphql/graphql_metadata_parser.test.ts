import { describe, expect, it } from 'vitest';

import {
  GraphqlMetadataParser,
  GraphqlMetadataSeverity,
  PhysicalObjectKind,
  type PhysicalCatalog,
} from '../../src';

describe('GraphqlMetadataParser', () => {
  it('parses JSONC and emits view_missing_identity for published views without key', () => {
    const parser = new GraphqlMetadataParser();

    const result = parser.parse({
      rawJsonc: `
{
  // JSONC comment
  version: 1,
  objects: {
    "sales.vw_OrderSummary": {
      publish: true,
    },
  },
}
`,
      physicalCatalog: physicalCatalog(),
    });

    expect(result.metadata).not.toBeNull();
    expect(result.metadata?.version).toBe(1);
    expect(Object.keys(result.metadata?.objects ?? {})).toEqual(['sales.vw_OrderSummary']);
    expect(result.diagnostics).toHaveLength(1);
    expect(result.diagnostics[0]?.severity).toBe(GraphqlMetadataSeverity.Error);
    expect(result.diagnostics[0]?.code).toBe('view_missing_identity');
    expect(result.diagnostics[0]?.objectId).toBe('sales.vw_OrderSummary');
  });

  it('emits metadata_object_unknown for declared objects absent from the physical model', () => {
    const parser = new GraphqlMetadataParser();

    const result = parser.parse({
      rawJsonc: `
{
  version: 1,
  objects: {
    "sales.Missing": {
      publish: true,
    },
  },
}
`,
      physicalCatalog: physicalCatalog(),
    });

    expect(Object.keys(result.metadata?.objects ?? {})).toEqual(['sales.Missing']);
    expect(result.diagnostics).toHaveLength(1);
    expect(result.diagnostics[0]?.code).toBe('metadata_object_unknown');
    expect(result.diagnostics[0]?.objectId).toBe('sales.Missing');
  });

  it('rejects defaults and object limits where default is greater than max', () => {
    const parser = new GraphqlMetadataParser();

    const result = parser.parse({
      rawJsonc: `
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
`,
      physicalCatalog: physicalCatalog(),
    });

    expect(result.diagnostics.map((diagnostic) => diagnostic.code)).toEqual([
      'metadata_invalid_shape',
      'metadata_invalid_shape',
    ]);
    expect(result.diagnostics.filter((diagnostic) => diagnostic.field === 'defaults.limit')).toHaveLength(1);
    expect(result.diagnostics.filter((diagnostic) => diagnostic.field === 'sales.Customer.limit')).toHaveLength(1);
  });

  it('sorts mixed error and warning diagnostics canonically', () => {
    const parser = new GraphqlMetadataParser();

    const result = parser.parse({
      rawJsonc: `
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
`,
      physicalCatalog: physicalCatalog(),
    });

    expect(
      result.diagnostics.map(
        (diagnostic) => `${diagnostic.severity}|${diagnostic.code}|${diagnostic.objectId ?? ''}|${diagnostic.field ?? ''}`,
      ),
    ).toEqual([
      'error|metadata_object_unknown|sales.Unknown|',
      'error|view_missing_identity|sales.vw_OrderSummary|',
      'warning|metadata_unknown_key||futureKey',
      'warning|metadata_unknown_key|sales.Unknown|stray',
    ]);
  });

  it('keeps a strict allowlist of declared publish true objects and leaves absent objects unpublished', () => {
    const parser = new GraphqlMetadataParser();

    const result = parser.parse({
      rawJsonc: `
{
  version: 1,
  objects: {
    "sales.Customer": {
      publish: true,
    },
  },
}
`,
      physicalCatalog: physicalCatalog(),
    });

    expect(Object.keys(result.metadata?.objects ?? {})).toEqual(['sales.Customer']);
    expect(result.metadata?.objects['sales.vw_OrderSummary']).toBeUndefined();
    expect(result.diagnostics).toEqual([]);
  });

  it('parses field relation and limit overrides into strongly typed metadata', () => {
    const parser = new GraphqlMetadataParser();

    const result = parser.parse({
      rawJsonc: `
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
`,
      physicalCatalog: physicalCatalog(),
    });

    const customer = result.metadata?.objects['sales.Customer'];
    expect(customer).toBeDefined();
    expect(customer?.name).toBe('CustomerRecord');
    expect(customer?.key).toEqual(['CustomerId']);
    expect(result.metadata?.defaultsLimit).toEqual({ defaultValue: 50, maxValue: 200 });
    expect(customer?.limit).toEqual({ defaultValue: 25, maxValue: 100 });
    expect(Object.keys(customer?.fields ?? {})).toEqual(['CustomerCode', 'FullName']);
    expect(customer?.fields['CustomerCode']).toEqual({
      hidden: true,
      sensitive: false,
      noFilter: true,
      noSort: false,
      name: 'customerCode',
    });
    expect(customer?.fields['FullName']).toEqual({
      hidden: false,
      sensitive: true,
      noFilter: false,
      noSort: true,
      name: undefined,
    });
    expect(customer?.relations).toEqual([
      {
        name: 'orders',
        cardinality: 'to-many',
        target: 'sales.Order',
        via: ['CustomerId'],
      },
    ]);
    expect(result.diagnostics).toEqual([]);
  });
});

function physicalCatalog(): PhysicalCatalog {
  return {
    objects: [
      {
        id: 'sales.Customer',
        kind: PhysicalObjectKind.Table,
        schemaName: 'sales',
        objectName: 'Customer',
        identityFields: ['CustomerId'],
        fields: [],
        relations: [],
      },
      {
        id: 'sales.vw_OrderSummary',
        kind: PhysicalObjectKind.View,
        schemaName: 'sales',
        objectName: 'vw_OrderSummary',
        identityFields: [],
        fields: [],
        relations: [],
      },
    ],
  };
}