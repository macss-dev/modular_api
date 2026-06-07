import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { AddressInfo } from 'node:net';

import {
  GraphqlClient,
  GraphqlRequest,
  ServiceClientConfig,
  ServiceFailureCategory,
  graphqlClient,
} from '../src';

import { afterEach, describe, expect, it } from 'vitest';

describe('graphqlClient', () => {
  const servers: Array<ReturnType<typeof createServer>> = [];

  afterEach(async () => {
    await Promise.all(
      servers.map(
        (server) =>
          new Promise<void>((resolve, reject) => {
            server.close((error) => (error ? reject(error) : resolve()));
          }),
      ),
    );
    servers.length = 0;
  });

  it('sends a POST request to /graphql and decodes the GraphQL envelope', async () => {
    const server = await startServer(async (req, res) => {
      expect(req.method).toBe('POST');
      expect(req.url).toBe('/graphql');
      expect(req.headers['x-default']).toBe('package');
      expect(req.headers['x-request']).toBe('test');

      const body = JSON.parse(await readBody(req)) as Record<string, unknown>;
      expect(body.query).toBe('query GetUsers { users { id } }');
      expect(body.operationName).toBe('GetUsers');
      expect(body.variables).toEqual({ limit: 10 });

      res.statusCode = 200;
      res.setHeader('content-type', 'application/json');
      res.setHeader('x-request-id', 'req-graphql-1');
      res.end(
        JSON.stringify({
          data: { users: [{ id: '1' }] },
          extensions: { traceId: 'trace-1' },
        }),
      );
    }, servers);

    const result = await graphqlClient<Record<string, unknown>>({
      config: new ServiceClientConfig({
        serviceId: 'users-graphql',
        baseUrl: server.baseUrl,
        redactedSummary: 'users-graphql@local',
        defaultHeaders: { 'x-default': 'package' },
      }),
      request: new GraphqlRequest({
        operationId: 'users.query',
        document: 'query GetUsers { users { id } }',
        operationName: 'GetUsers',
        variables: { limit: 10 },
        headers: { 'x-request': 'test' },
      }),
      decoder: (value) => value as Record<string, unknown>,
    });

    expect(result.isSuccess).toBe(true);
    expect(result.value.data?.users).toEqual([{ id: '1' }]);
    expect(result.value.errors).toEqual([]);
    expect(result.value.extensions).toEqual({ traceId: 'trace-1' });
    expect(result.value.metadata.statusCode).toBe(200);
    expect(result.value.metadata.transportId).toBe('graphql');
    expect(result.value.metadata.requestId).toBe('req-graphql-1');
  });

  it('preserves GraphQL errors without collapsing them into transport failures', async () => {
    const server = await startServer(async (_req, res) => {
      res.statusCode = 200;
      res.setHeader('content-type', 'application/json');
      res.end(
        JSON.stringify({
          data: null,
          errors: [
            {
              message: 'Field users is not available',
              path: ['users'],
              extensions: { code: 'FIELD_UNAVAILABLE' },
            },
          ],
        }),
      );
    }, servers);

    const result = await graphqlClient<unknown>({
      config: new ServiceClientConfig({
        serviceId: 'users-graphql',
        baseUrl: server.baseUrl,
        redactedSummary: 'users-graphql@local',
      }),
      request: new GraphqlRequest({
        operationId: 'users.error',
        document: 'query Broken { users }',
      }),
    });

    expect(result.isSuccess).toBe(true);
    expect(result.value.data).toBeNull();
    expect(result.value.errors).toHaveLength(1);
    expect(result.value.errors[0].message).toBe('Field users is not available');
    expect(result.value.errors[0].path).toEqual(['users']);
    expect(result.value.errors[0].extensions).toEqual({ code: 'FIELD_UNAVAILABLE' });
  });

  it('injects auth headers from the auth provider', async () => {
    const server = await startServer(async (req, res) => {
      expect(req.headers.authorization).toBe('Bearer token-123');
      res.statusCode = 200;
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({ data: { ok: true } }));
    }, servers);

    const result = await graphqlClient<Record<string, unknown>>({
      config: new ServiceClientConfig({
        serviceId: 'users-graphql',
        baseUrl: server.baseUrl,
        redactedSummary: 'users-graphql@local',
        authProvider: async (operation) => {
          expect(operation.operationId).toBe('users.auth');
          return { authorization: 'Bearer token-123' };
        },
      }),
      request: new GraphqlRequest({
        operationId: 'users.auth',
        document: 'query Viewer { viewer { id } }',
      }),
      decoder: (value) => value as Record<string, unknown>,
    });

    expect(result.isSuccess).toBe(true);
    expect(result.value.data?.ok).toBe(true);
  });

  it('returns a timeout failure when the request exceeds the configured timeout', async () => {
    const server = await startServer(async (_req, res) => {
      await new Promise((resolve) => setTimeout(resolve, 200));
      res.statusCode = 200;
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({ data: { late: true } }));
    }, servers);

    const result = await graphqlClient<unknown>({
      config: new ServiceClientConfig({
        serviceId: 'slow-graphql',
        baseUrl: server.baseUrl,
        redactedSummary: 'slow-graphql@local',
        timeout: 20,
      }),
      request: new GraphqlRequest({
        operationId: 'users.timeout',
        document: 'query Slow { slow }',
      }),
    });

    expect(result.isFailure).toBe(true);
    expect(result.failure.category).toBe(ServiceFailureCategory.timeout);
    expect(result.failure.code).toBe('timeout');
    expect(result.failure.retryable).toBe(true);
  });

  it('keeps transport failures separate from GraphQL envelopes', async () => {
    const server = await startServer(async (_req, res) => {
      res.statusCode = 401;
      res.end('missing token');
    }, servers);

    const result = await graphqlClient<unknown>({
      config: new ServiceClientConfig({
        serviceId: 'users-graphql',
        baseUrl: server.baseUrl,
        redactedSummary: 'users-graphql@local',
      }),
      request: new GraphqlRequest({
        operationId: 'users.transport',
        document: 'query Viewer { viewer { id } }',
      }),
    });

    expect(result.isFailure).toBe(true);
    expect(result.failure.category).toBe(ServiceFailureCategory.auth);
    expect(result.failure.code).toBe('unauthorized');
    expect(result.failure.statusCode).toBe(401);
  });

  it('rejects mutation documents because the client is query-only in v1', async () => {
    const result = await graphqlClient<unknown>({
      config: new ServiceClientConfig({
        serviceId: 'users-graphql',
        baseUrl: 'https://example.test',
        redactedSummary: 'users-graphql@example',
      }),
      request: new GraphqlRequest({
        operationId: 'users.mutation',
        document: 'mutation UpdateUser { updateUser(id: 1) { id } }',
      }),
    });

    expect(result.isFailure).toBe(true);
    expect(result.failure.category).toBe(ServiceFailureCategory.graphql);
    expect(result.failure.code).toBe('mutation_not_supported');
  });
});

describe('GraphqlClient', () => {
  it('describes its config and closes cleanly', async () => {
    const client = new GraphqlClient(
      new ServiceClientConfig({
        serviceId: 'users-graphql',
        baseUrl: 'https://example.test',
        redactedSummary: 'users-graphql@example',
      }),
    );

    expect(client.describe().serviceId).toBe('users-graphql');
    expect(client.describe().transportId).toBe('graphql');

    const closed = await client.close();
    expect(closed.isSuccess).toBe(true);
  });
});

async function startServer(
  handler: (request: IncomingMessage, response: ServerResponse) => void | Promise<void>,
  registry: Array<ReturnType<typeof createServer>>,
): Promise<{ baseUrl: string }> {
  const server = createServer((request, response) => {
    void Promise.resolve(handler(request, response)).catch((error: unknown) => {
      response.statusCode = 500;
      response.end(String(error));
    });
  });
  registry.push(server);

  await new Promise<void>((resolve, reject) => {
    server.listen(0, '127.0.0.1', (error?: Error) => {
      if (error) {
        reject(error);
        return;
      }
      resolve();
    });
  });

  const address = server.address() as AddressInfo;
  return { baseUrl: `http://127.0.0.1:${address.port}` };
}

async function readBody(request: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  return Buffer.concat(chunks).toString('utf8');
}