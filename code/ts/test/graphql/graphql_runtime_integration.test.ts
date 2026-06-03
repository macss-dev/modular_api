import type { Server } from 'http';

import request from 'supertest';
import { afterEach, describe, expect, it } from 'vitest';

import {
  Capability,
  GraphqlCatalogBuildMode,
  GraphqlCatalogFieldVisibility,
  GraphqlCatalogIdentityMode,
  GraphqlCatalogOrigin,
  GraphqlCatalogPaginationMode,
  GraphqlOptions,
  ModularApi,
  PhysicalObjectKind,
  PluginHostError,
  ReadExecutionContext,
  RowSet,
  type GraphqlCatalog,
  type Plugin,
  type PluginHost,
  type PluginManifest,
  type ReadExecutor,
  type SqlReadCommand,
} from '../../src';
import { apiRegistry } from '../../src/core/registry';

describe('GraphQL runtime integration', () => {
  let server: Server | undefined;

  afterEach(async () => {
    if (server) {
      await closeServer(server);
      server = undefined;
    }
    apiRegistry.clear();
  });

  it('health reports graphql disabled and endpoint is absent by default', async () => {
    const api = new ModularApi({
      basePath: '/api',
      title: 'GraphQL Test API',
      version: '1.0.0',
    });

    server = await api.serve({ port: 0 });

    const graphqlResponse = await request(server)
      .post('/api/graphql')
      .set('Content-Type', 'application/json')
      .send({ query: '{ __typename }' });
    expect(graphqlResponse.status).toBe(404);

    const healthResponse = await request(server).get('/api/health');
    expect(healthResponse.status).toBe(200);
    expect(healthResponse.body.checks.graphql.status).toBe('pass');
    expect(healthResponse.body.checks.graphql.output).toBe('disabled');
  });

  it('GraphqlOptions defaults introspection false maxDepth 8 and maxComplexity 500', () => {
    const options = new GraphqlOptions({
      catalogFactory: async () => catalogFixture(),
      executor: new NoopExecutor(),
    });

    expect(options.introspectionEnabled).toBe(false);
    expect(options.maxDepth).toBe(8);
    expect(options.maxComplexity).toBe(500);
    expect(options.executionCapabilityId).toBeUndefined();
  });

  it('graphql endpoint mounts under basePath and health reports ready when startup succeeds', async () => {
    const api = new ModularApi({
      basePath: '/api',
      title: 'GraphQL Test API',
      version: '1.0.0',
      graphql: new GraphqlOptions({
        catalogFactory: async () => catalogFixture(),
        executionCapabilityId: 'modular_api.sql.read_executor',
      }),
    }).plugin(
      new ExecutorCapabilityPlugin({
        id: 'acme.sql.read-executor',
        capabilityId: 'modular_api.sql.read_executor',
        executor: new NoopExecutor(),
      }),
    );

    server = await api.serve({ port: 0 });

    const graphqlResponse = await request(server)
      .post('/api/graphql')
      .set('Content-Type', 'application/json')
      .send({ query: '{ __typename }' });
    expect(graphqlResponse.status).toBe(200);
    expect(graphqlResponse.body).toEqual({ data: { __typename: 'Query' } });

    const healthResponse = await request(server).get('/api/health');
    expect(healthResponse.status).toBe(200);
    expect(healthResponse.body.checks.graphql.status).toBe('pass');
    expect(healthResponse.body.checks.graphql.output).toBe('ready');
  });

  it('startup fails when catalog construction fails', async () => {
    const api = new ModularApi({
      basePath: '/api',
      graphql: new GraphqlOptions({
        catalogFactory: async () => {
          throw new Error('introspection failed');
        },
        executor: new NoopExecutor(),
      }),
    });

    await expect(api.serve({ port: 0 })).rejects.toMatchObject<Partial<PluginHostError>>({
      code: 'PLUGIN_VALIDATION_FAILED',
      resourceId: 'graphql.catalog',
    });
  });

  it('startup fails when executor capability is missing', async () => {
    const api = new ModularApi({
      basePath: '/api',
      graphql: new GraphqlOptions({
        catalogFactory: async () => catalogFixture(),
        executionCapabilityId: 'missing.sql.read_executor',
      }),
    });

    await expect(api.serve({ port: 0 })).rejects.toMatchObject<Partial<PluginHostError>>({
      code: 'PLUGIN_VALIDATION_FAILED',
      resourceId: 'missing.sql.read_executor',
    });
  });

  it('startup fails when schema generation fails', async () => {
    const api = new ModularApi({
      basePath: '/api',
      graphql: new GraphqlOptions({
        catalogFactory: async () => catalogFixture(),
        executor: new NoopExecutor(),
        sdlFactory: () => 'type Query {',
      }),
    });

    await expect(api.serve({ port: 0 })).rejects.toMatchObject<Partial<PluginHostError>>({
      code: 'PLUGIN_VALIDATION_FAILED',
      resourceId: 'graphql.schema',
    });
  });

  it('startup fails when maxDepth is invalid', async () => {
    const api = new ModularApi({
      basePath: '/api',
      graphql: new GraphqlOptions({
        catalogFactory: async () => catalogFixture(),
        executor: new NoopExecutor(),
        maxDepth: 0,
      }),
    });

    await expect(api.serve({ port: 0 })).rejects.toMatchObject<Partial<PluginHostError>>({
      code: 'PLUGIN_VALIDATION_FAILED',
      resourceId: 'graphql.maxDepth',
    });
  });

  it('startup fails when maxComplexity is invalid', async () => {
    const api = new ModularApi({
      basePath: '/api',
      graphql: new GraphqlOptions({
        catalogFactory: async () => catalogFixture(),
        executor: new NoopExecutor(),
        maxComplexity: -1,
      }),
    });

    await expect(api.serve({ port: 0 })).rejects.toMatchObject<Partial<PluginHostError>>({
      code: 'PLUGIN_VALIDATION_FAILED',
      resourceId: 'graphql.maxComplexity',
    });
  });

  it('direct executor and capability id are mutually exclusive', () => {
    expect(
      () =>
        new GraphqlOptions({
          catalogFactory: async () => catalogFixture(),
          executor: new NoopExecutor(),
          executionCapabilityId: 'modular_api.sql.read_executor',
        }),
    ).toThrowError();
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

class ExecutorCapabilityPlugin implements Plugin {
  readonly manifest: PluginManifest;
  private readonly capabilityId: string;
  private readonly executor: ReadExecutor;

  constructor(options: { id: string; capabilityId: string; executor: ReadExecutor }) {
    this.capabilityId = options.capabilityId;
    this.executor = options.executor;
    this.manifest = {
      id: options.id,
      displayName: 'Executor Capability Plugin',
      version: '0.1.0',
      hostApiVersion: '>=0.1.0 <0.2.0',
    };
  }

  setup(host: PluginHost): void {
    host.exposeCapability(
      {
        id: this.capabilityId,
        version: '1.0.0',
        value: this.executor,
      } as Capability<ReadExecutor>,
    );
  }
}

class NoopExecutor implements ReadExecutor {
  async close(): Promise<void> {}

  async execute(_command: SqlReadCommand, _context: ReadExecutionContext): Promise<RowSet> {
    return new RowSet({ rows: [], rowCount: 0 });
  }
}

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