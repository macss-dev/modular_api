import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { Server } from 'node:http';

import request from 'supertest';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import {
  GraphqlArtifactCompiler,
  GraphqlCatalogBuildMode,
  GraphqlCatalogDiagnosticSeverity,
  GraphqlCatalogFieldVisibility,
  GraphqlCatalogIdentityMode,
  GraphqlCatalogOrigin,
  GraphqlCatalogPaginationMode,
  GraphqlOptions,
  ModularApi,
  PhysicalObjectKind,
  ReadExecutionContext,
  RowSet,
  type GraphqlCatalog,
  type GraphqlCatalogDiagnostic,
  type GraphqlPublishedObject,
  type ReadExecutor,
  type SqlReadCommand,
} from '../../src';
import { apiRegistry } from '../../src/core/registry';

describe('GraphQL artifact compiler', () => {
  let outputDir: string;

  beforeEach(async () => {
    outputDir = await mkdtemp(join(tmpdir(), 'graphql-artifacts-'));
  });

  afterEach(async () => {
    apiRegistry.clear();
    await rm(outputDir, { recursive: true, force: true });
  });

  it('compile mode emits catalog.json catalog.lock diagnostics.json and schema.graphql', async () => {
    const compiler = new GraphqlArtifactCompiler({
      catalogFactory: async () => catalogOrdered(),
    });

    const bundle = await compiler.writeToDirectory(outputDir);

    expect(bundle.catalogJson.length).toBeGreaterThan(0);
    expect(bundle.catalogLockJson.length).toBeGreaterThan(0);
    expect(bundle.diagnosticsJson.length).toBeGreaterThan(0);
    expect(bundle.schemaGraphql.length).toBeGreaterThan(0);

    await expect(stat(artifactPath(outputDir, 'catalog.json'))).resolves.toBeDefined();
    await expect(stat(artifactPath(outputDir, 'catalog.lock'))).resolves.toBeDefined();
    await expect(stat(artifactPath(outputDir, 'diagnostics.json'))).resolves.toBeDefined();
    await expect(stat(artifactPath(outputDir, 'schema.graphql'))).resolves.toBeDefined();
  });

  it('emitted artifacts are byte stable for identical inputs', async () => {
    const leftDir = await mkdtemp(join(tmpdir(), 'graphql-artifacts-left-'));
    const rightDir = await mkdtemp(join(tmpdir(), 'graphql-artifacts-right-'));

    try {
      await new GraphqlArtifactCompiler({
        catalogFactory: async () => catalogOrdered(),
      }).writeToDirectory(leftDir);
      await new GraphqlArtifactCompiler({
        catalogFactory: async () => catalogOrdered(),
      }).writeToDirectory(rightDir);

      await expect(readFile(artifactPath(leftDir, 'catalog.json'), 'utf8')).resolves.toEqual(
        await readFile(artifactPath(rightDir, 'catalog.json'), 'utf8'),
      );
      await expect(readFile(artifactPath(leftDir, 'catalog.lock'), 'utf8')).resolves.toEqual(
        await readFile(artifactPath(rightDir, 'catalog.lock'), 'utf8'),
      );
      await expect(readFile(artifactPath(leftDir, 'diagnostics.json'), 'utf8')).resolves.toEqual(
        await readFile(artifactPath(rightDir, 'diagnostics.json'), 'utf8'),
      );
      await expect(readFile(artifactPath(leftDir, 'schema.graphql'), 'utf8')).resolves.toEqual(
        await readFile(artifactPath(rightDir, 'schema.graphql'), 'utf8'),
      );
    } finally {
      await rm(leftDir, { recursive: true, force: true });
      await rm(rightDir, { recursive: true, force: true });
    }
  });

  it('catalog and diagnostics artifacts are independent of source discovery order', async () => {
    const leftDir = await mkdtemp(join(tmpdir(), 'graphql-artifacts-ordered-'));
    const rightDir = await mkdtemp(join(tmpdir(), 'graphql-artifacts-reversed-'));

    try {
      await new GraphqlArtifactCompiler({
        catalogFactory: async () => catalogOrdered(),
      }).writeToDirectory(leftDir);
      await new GraphqlArtifactCompiler({
        catalogFactory: async () => catalogDiscoveredOutOfOrder(),
      }).writeToDirectory(rightDir);

      await expect(readFile(artifactPath(leftDir, 'catalog.json'), 'utf8')).resolves.toEqual(
        await readFile(artifactPath(rightDir, 'catalog.json'), 'utf8'),
      );
      await expect(readFile(artifactPath(leftDir, 'diagnostics.json'), 'utf8')).resolves.toEqual(
        await readFile(artifactPath(rightDir, 'diagnostics.json'), 'utf8'),
      );
    } finally {
      await rm(leftDir, { recursive: true, force: true });
      await rm(rightDir, { recursive: true, force: true });
    }
  });

  it('authoritative artifacts omit volatile execution time data and lock includes sourceDigest', async () => {
    await new GraphqlArtifactCompiler({
      catalogFactory: async () => catalogOrdered(),
    }).writeToDirectory(outputDir);

    const catalogJson = await readFile(artifactPath(outputDir, 'catalog.json'), 'utf8');
    const catalogLockJson = await readFile(artifactPath(outputDir, 'catalog.lock'), 'utf8');
    const diagnosticsJson = await readFile(artifactPath(outputDir, 'diagnostics.json'), 'utf8');

    expect(catalogJson).not.toContain('generatedAt');
    expect(catalogLockJson).not.toContain('generatedAt');
    expect(diagnosticsJson).not.toContain('generatedAt');

    const lock = JSON.parse(catalogLockJson) as Record<string, unknown>;
    expect(lock.catalogVersion).toBe('1.0.0');
    expect(lock.sourceDigest).toBe('digest-a');
    expect(lock.providerVersion).toBe('0.4.7-test');
  });

  it('runtime fast path loads valid prebuilt artifacts successfully', async () => {
    await new GraphqlArtifactCompiler({
      catalogFactory: async () => catalogOrdered(),
    }).writeToDirectory(outputDir);

    const api = new ModularApi({
      basePath: '/api',
      title: 'GraphQL Artifact API',
      version: '1.0.0',
      graphql: new GraphqlOptions({
        artifactDirectory: outputDir,
        sourceDigestFactory: async () => 'digest-a',
        catalogFactory: async () => {
          throw new Error('catalogFactory should not run on fast path');
        },
        executor: new NoopExecutor(),
      }),
    });

    let server: Server | undefined;
    try {
      server = await api.serve({ port: 0 });
      const response = await request(server)
        .post('/api/graphql')
        .set('Content-Type', 'application/json')
        .send({ query: '{ customerRecordList { items { customerId } } }' });

      expect(response.status).toBe(200);
      expect(response.body).toEqual({
        data: {
          customerRecordList: { items: [] },
        },
      });
    } finally {
      if (server) {
        await closeServer(server);
      }
    }
  });

  it('drift between normalized inputs and catalog.lock is detected and falls back to source compilation', async () => {
    await new GraphqlArtifactCompiler({
      catalogFactory: async () => catalogOrdered(),
    }).writeToDirectory(outputDir);

    let sourceCompilations = 0;
    const api = new ModularApi({
      basePath: '/api',
      title: 'GraphQL Artifact API',
      version: '1.0.0',
      graphql: new GraphqlOptions({
        artifactDirectory: outputDir,
        sourceDigestFactory: async () => 'digest-b',
        catalogFactory: async () => {
          sourceCompilations += 1;
          return catalogOrdered({ sourceDigest: 'digest-b' });
        },
        executor: new NoopExecutor(),
      }),
    });

    let server: Server | undefined;
    try {
      server = await api.serve({ port: 0 });
      expect(sourceCompilations).toBe(1);
    } finally {
      if (server) {
        await closeServer(server);
      }
    }
  });
});

function artifactPath(directory: string, fileName: string): string {
  return join(directory, fileName);
}

function catalogOrdered(options: { sourceDigest?: string } = {}): GraphqlCatalog {
  return {
    catalogVersion: '1.0.0',
    provider: {
      kind: 'sql',
      engine: 'sqlserver',
      providerVersion: '0.4.7-test',
    },
    build: {
      mode: GraphqlCatalogBuildMode.Compile,
      sourceRoot: 'db/src',
      sourceDigest: options.sourceDigest ?? 'digest-a',
    },
    objects: [customerObject(), orderObject()],
    diagnostics: [
      diagnostic({ severity: GraphqlCatalogDiagnosticSeverity.Warning, code: 'alpha_warning', message: 'alpha' }),
      diagnostic({ severity: GraphqlCatalogDiagnosticSeverity.Info, code: 'beta_info', message: 'beta' }),
    ],
  };
}

function catalogDiscoveredOutOfOrder(): GraphqlCatalog {
  return {
    catalogVersion: '1.0.0',
    provider: {
      kind: 'sql',
      engine: 'sqlserver',
      providerVersion: '0.4.7-test',
    },
    build: {
      mode: GraphqlCatalogBuildMode.Compile,
      sourceRoot: 'db/src',
      sourceDigest: 'digest-a',
    },
    objects: [orderObject(), customerObject()],
    diagnostics: [
      diagnostic({ severity: GraphqlCatalogDiagnosticSeverity.Info, code: 'beta_info', message: 'beta' }),
      diagnostic({ severity: GraphqlCatalogDiagnosticSeverity.Warning, code: 'alpha_warning', message: 'alpha' }),
    ],
  };
}

function customerObject(): GraphqlPublishedObject {
  return {
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
  };
}

function orderObject(): GraphqlPublishedObject {
  return {
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
  };
}

function diagnostic(options: {
  severity: GraphqlCatalogDiagnosticSeverity;
  code: string;
  message: string;
}): GraphqlCatalogDiagnostic {
  return {
    severity: options.severity,
    code: options.code,
    message: options.message,
  };
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