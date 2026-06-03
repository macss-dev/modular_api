import type { Server } from 'http';

import request from 'supertest';
import { afterEach, describe, expect, it } from 'vitest';

import {
  GraphqlCatalogBuildMode,
  GraphqlCatalogFieldVisibility,
  GraphqlCatalogIdentityMode,
  GraphqlCatalogOrigin,
  GraphqlCatalogPaginationMode,
  GraphqlCatalogRelationCardinality,
  GraphqlOptions,
  GraphqlRequestPhase,
  ModularApi,
  PhysicalObjectKind,
  ReadExecutionContext,
  RowSet,
  SqlReadCommandPurpose,
  type GraphqlCatalog,
  type ReadExecutor,
  type SqlReadCommand,
} from '../../src';
import { apiRegistry } from '../../src/core/registry';

describe('GraphQL runtime execution', () => {
  let server: Server | undefined;

  afterEach(async () => {
    if (server) {
      await closeServer(server);
      server = undefined;
    }
    apiRegistry.clear();
  });

  it('relation resolution batches one command for many parents', async () => {
    const executor = new RecordingExecutor();
    const api = buildApi({ executor });

    server = await api.serve({ port: 0 });

    const response = await request(server)
      .post('/api/graphql')
      .set('Content-Type', 'application/json')
      .send({ query: '{ customerRecordList { items { customerId name orders { orderId customerId } } } }' });

    expect(response.status).toBe(200);
    expect(response.body).toEqual({
      data: {
        customerRecordList: {
          items: [
            {
              customerId: 1,
              name: 'Ada',
              orders: [
                { orderId: 10, customerId: 1 },
                { orderId: 11, customerId: 1 },
              ],
            },
            {
              customerId: 2,
              name: 'Linus',
              orders: [{ orderId: 20, customerId: 2 }],
            },
          ],
        },
      },
    });

    expect(executor.commands.filter((command) => command.purpose === SqlReadCommandPurpose.Collection)).toHaveLength(1);
    expect(executor.commands.filter((command) => command.purpose === SqlReadCommandPurpose.RelationBatch)).toHaveLength(1);
  });

  it('totalCount runs only when selected', async () => {
    const executor = new RecordingExecutor();
    const api = buildApi({ executor });

    server = await api.serve({ port: 0 });

    const withoutCount = await request(server)
      .post('/api/graphql')
      .set('Content-Type', 'application/json')
      .send({ query: '{ customerRecordList { items { customerId } } }' });
    expect(withoutCount.status).toBe(200);
    expect(executor.commands.filter((command) => command.purpose === SqlReadCommandPurpose.Count)).toHaveLength(0);

    executor.reset();

    const withCount = await request(server)
      .post('/api/graphql')
      .set('Content-Type', 'application/json')
      .send({ query: '{ customerRecordList { items { customerId } totalCount } }' });
    expect(withCount.status).toBe(200);
    expect(executor.commands.filter((command) => command.purpose === SqlReadCommandPurpose.Collection)).toHaveLength(1);
    expect(executor.commands.filter((command) => command.purpose === SqlReadCommandPurpose.Count)).toHaveLength(1);
    expect(withCount.body).toEqual({
      data: {
        customerRecordList: {
          items: [{ customerId: 1 }, { customerId: 2 }],
          totalCount: 2,
        },
      },
    });
  });

  it('app pagination narrows catalog defaults and omitted page uses effective default', async () => {
    const executor = new RecordingExecutor();
    const api = buildApi({
      executor,
      defaultLimit: 20,
      maxLimit: 80,
    });

    server = await api.serve({ port: 0 });

    const response = await request(server)
      .post('/api/graphql')
      .set('Content-Type', 'application/json')
      .send({ query: '{ customerRecordList { items { customerId } } }' });

    expect(response.status).toBe(200);
    const collectionCommand = executor.commands.find((command) => command.purpose === SqlReadCommandPurpose.Collection);
    expect(collectionCommand?.parameters.map((parameter) => parameter.value)).toEqual([0, 20]);
  });

  it('client page limit above effective max fails validation instead of clamping', async () => {
    const executor = new RecordingExecutor();
    const api = buildApi({
      executor,
      defaultLimit: 20,
      maxLimit: 80,
    });

    server = await api.serve({ port: 0 });

    const response = await request(server)
      .post('/api/graphql')
      .set('Content-Type', 'application/json')
      .send({ query: '{ customerRecordList(page: { limit: 90 }) { items { customerId } } }' });

    expect(response.status).toBe(200);
    expect(response.body.errors[0].message).toContain('effective max limit');
    expect(executor.commands).toHaveLength(0);
  });

  it('negative page values fail validation and offset defaults to zero', async () => {
    const executor = new RecordingExecutor();
    const api = buildApi({ executor });

    server = await api.serve({ port: 0 });

    const negativeResponse = await request(server)
      .post('/api/graphql')
      .set('Content-Type', 'application/json')
      .send({ query: '{ customerRecordList(page: { limit: -1, offset: -2 }) { items { customerId } } }' });
    expect(negativeResponse.status).toBe(200);
    expect(negativeResponse.body.errors[0].message).toContain('must be non-negative');
    expect(executor.commands).toHaveLength(0);

    executor.reset();

    const offsetDefaultResponse = await request(server)
      .post('/api/graphql')
      .set('Content-Type', 'application/json')
      .send({ query: '{ customerRecordList(page: { limit: 5 }) { items { customerId } } }' });
    expect(offsetDefaultResponse.status).toBe(200);
    const collectionCommand = executor.commands.find((command) => command.purpose === SqlReadCommandPurpose.Collection);
    expect(collectionCommand?.parameters.map((parameter) => parameter.value)).toEqual([0, 5]);
  });

  it('page limit zero yields empty items and still allows totalCount', async () => {
    const executor = new RecordingExecutor();
    const api = buildApi({ executor });

    server = await api.serve({ port: 0 });

    const response = await request(server)
      .post('/api/graphql')
      .set('Content-Type', 'application/json')
      .send({ query: '{ customerRecordList(page: { limit: 0 }) { items { customerId } totalCount } }' });

    expect(response.status).toBe(200);
    expect(response.body).toEqual({
      data: {
        customerRecordList: {
          items: [],
          totalCount: 2,
        },
      },
    });
    expect(executor.commands.filter((command) => command.purpose === SqlReadCommandPurpose.Collection)).toHaveLength(0);
    expect(executor.commands.filter((command) => command.purpose === SqlReadCommandPurpose.Count)).toHaveLength(1);
  });

  it('request scoped execution context reaches executor', async () => {
    const executor = new RecordingExecutor();
    const api = buildApi({ executor });

    server = await api.serve({ port: 0 });

    const response = await request(server)
      .post('/api/graphql')
      .set('Content-Type', 'application/json')
      .set('X-Request-ID', 'req-123')
      .set('X-Tenant-ID', 'tenant-a')
      .set('X-Principal', 'user-a')
      .send({ query: '{ customerRecordList { items { customerId } } }' });

    expect(response.status).toBe(200);
    const context = executor.contexts[0];
    expect(context?.requestId).toBe('req-123');
    expect(context?.tenantId).toBe('tenant-a');
    expect(context?.principal).toBe('user-a');
  });

  it('query depth limits are enforced', async () => {
    const executor = new RecordingExecutor();
    const api = buildApi({
      executor,
      maxDepth: 2,
      maxComplexity: 500,
    });

    server = await api.serve({ port: 0 });

    const response = await request(server)
      .post('/api/graphql')
      .set('Content-Type', 'application/json')
      .send({ query: '{ customerRecordList { items { orders { orderId } } } }' });

    expect(response.status).toBe(200);
    expect(response.body.errors[0].extensions.validationError.code).toBe('queryDepthComplexity');
    expect(executor.commands).toHaveLength(0);
  });

  it('query complexity limits are enforced', async () => {
    const executor = new RecordingExecutor();
    const api = buildApi({
      executor,
      maxDepth: 8,
      maxComplexity: 5,
    });

    server = await api.serve({ port: 0 });

    const response = await request(server)
      .post('/api/graphql')
      .set('Content-Type', 'application/json')
      .send({ query: '{ customerRecordList { items { customerId } } }' });

    expect(response.status).toBe(200);
    expect(response.body.errors[0].extensions.validationError.code).toBe('queryComplexity');
    expect(executor.commands).toHaveLength(0);
  });

  it('introspection when enabled remains subject to the same limits', async () => {
    const executor = new RecordingExecutor();
    const api = buildApi({
      executor,
      introspectionEnabled: true,
      maxDepth: 1,
    });

    server = await api.serve({ port: 0 });

    const response = await request(server)
      .post('/api/graphql')
      .set('Content-Type', 'application/json')
      .send({ query: '{ __schema { queryType { name } } }' });

    expect(response.status).toBe(200);
    expect(response.body.errors[0].extensions.validationError.code).toBe('queryDepthComplexity');
    expect(executor.commands).toHaveLength(0);
  });

  it('telemetry hook captures graphql request lifecycle events', async () => {
    const executor = new RecordingExecutor();
    const events: Array<{
      phase: GraphqlRequestPhase;
      requestId: string;
      statusCode?: number;
    }> = [];
    const api = buildApi({
      executor,
      onEvent: (event) => {
        events.push({
          phase: event.phase,
          requestId: event.requestId,
          statusCode: event.statusCode,
        });
      },
    });

    server = await api.serve({ port: 0 });

    const response = await request(server)
      .post('/api/graphql')
      .set('Content-Type', 'application/json')
      .set('X-Request-ID', 'req-telemetry')
      .send({ query: '{ customerRecordList { items { customerId } } }' });

    expect(response.status).toBe(200);
    expect(events).toEqual([
      { phase: GraphqlRequestPhase.Started, requestId: 'req-telemetry', statusCode: undefined },
      { phase: GraphqlRequestPhase.Completed, requestId: 'req-telemetry', statusCode: 200 },
    ]);
  });
});

function buildApi(options: {
  executor: ReadExecutor;
  maxDepth?: number;
  maxComplexity?: number;
  defaultLimit?: number;
  maxLimit?: number;
  introspectionEnabled?: boolean;
  onEvent?: InstanceType<typeof GraphqlOptions>['onEvent'];
}): ModularApi {
  return new ModularApi({
    basePath: '/api',
    title: 'GraphQL Runtime API',
    version: '1.0.0',
    graphql: new GraphqlOptions({
      catalogFactory: async () => catalogFixture(),
      executor: options.executor,
      introspectionEnabled: options.introspectionEnabled,
      maxDepth: options.maxDepth,
      maxComplexity: options.maxComplexity,
      defaultLimit: options.defaultLimit,
      maxLimit: options.maxLimit,
      onEvent: options.onEvent,
    }),
  });
}

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
      sourceDigest: 'execution-test-digest',
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
            column: 'Name',
            publicName: 'name',
            type: 'String',
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
            name: 'orders',
            target: 'sales.Order',
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

    if (command.purpose === SqlReadCommandPurpose.Collection && command.sql.includes('[sales].[Customer]')) {
      const offset = Number(command.parameters[0]?.value ?? 0);
      const limit = Number(command.parameters[1]?.value ?? 0);
      const rows = customers.slice(offset, offset + limit);
      return new RowSet({ rows, rowCount: rows.length });
    }

    if (command.purpose === SqlReadCommandPurpose.Count && command.sql.includes('[sales].[Customer]')) {
      return new RowSet({ rows: [{ totalCount: 2 }], rowCount: 1 });
    }

    if (command.purpose === SqlReadCommandPurpose.RelationBatch && command.sql.includes('[sales].[Order]')) {
      const parentCustomerIds = new Set(command.parameters.map((parameter) => parameter.value).filter((value): value is number => typeof value === 'number'));
      const rows = orders.filter((row) => parentCustomerIds.has(Number(row.customerId)));
      return new RowSet({ rows, rowCount: rows.length });
    }

    throw new Error(`Unexpected command: ${command.purpose} ${command.sql}`);
  }

  async close(): Promise<void> {}

  reset(): void {
    this.commands.length = 0;
    this.contexts.length = 0;
  }
}

const customers = [
  { customerId: 1, name: 'Ada' },
  { customerId: 2, name: 'Linus' },
];

const orders = [
  { orderId: 10, customerId: 1 },
  { orderId: 11, customerId: 1 },
  { orderId: 20, customerId: 2 },
];

async function closeServer(server: Server): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    server.close((error) => {
      if (error) {
        reject(error);
        return;
      }
      resolve();
    });
  });
}