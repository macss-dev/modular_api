import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { AddressInfo } from 'node:net';

import {
  HttpServiceClient,
  ServiceClientConfig,
  ServiceFailureCategory,
  ServiceRequest,
  httpClient,
} from '../src';

import { afterEach, describe, expect, it } from 'vitest';

describe('httpClient', () => {
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

  it('sends a GET request, decodes JSON, and preserves metadata', async () => {
    const server = await startServer(async (req, res) => {
      const url = new URL(req.url ?? '/', 'http://127.0.0.1');

      expect(req.method).toBe('GET');
      expect(url.pathname).toBe('/users');
      expect(url.searchParams.get('name')).toBe('ana');
      expect(req.headers['x-default']).toBe('package');
      expect(req.headers['x-request']).toBe('test');

      res.statusCode = 200;
      res.setHeader('content-type', 'application/json');
      res.setHeader('x-request-id', 'req-123');
      res.end(JSON.stringify({ ok: true, name: 'Ana' }));
    }, servers);

    const result = await httpClient({
      config: new ServiceClientConfig({
        serviceId: 'users',
        baseUrl: server.baseUrl,
        redactedSummary: 'users@local',
        defaultHeaders: { 'x-default': 'package' },
      }),
      request: new ServiceRequest({
        operationId: 'get-users',
        method: 'GET',
        path: '/users',
        query: { name: 'ana' },
        headers: { 'x-request': 'test' },
      }),
      decoder: (value) => value as Record<string, unknown>,
    });

    expect(result.isSuccess).toBe(true);
    expect(result.value.data.ok).toBe(true);
    expect(result.value.data.name).toBe('Ana');
    expect(result.value.metadata.statusCode).toBe(200);
    expect(result.value.metadata.transportId).toBe('http');
    expect(result.value.metadata.requestId).toBe('req-123');
    expect(result.value.metadata.headers['x-request-id']).toBe('req-123');
  });

  it('returns a decode failure for invalid JSON responses', async () => {
    const server = await startServer(async (_req, res) => {
      res.statusCode = 200;
      res.setHeader('content-type', 'application/json');
      res.end('{broken-json');
    }, servers);

    const result = await httpClient({
      config: new ServiceClientConfig({
        serviceId: 'broken',
        baseUrl: server.baseUrl,
        redactedSummary: 'broken@local',
      }),
      request: new ServiceRequest({
        operationId: 'decode-failure',
        method: 'GET',
        path: '/broken',
      }),
    });

    expect(result.isFailure).toBe(true);
    expect(result.failure.category).toBe(ServiceFailureCategory.decode);
    expect(result.failure.code).toBe('invalid_json');
  });

  it('injects auth headers from the auth provider', async () => {
    const server = await startServer(async (req, res) => {
      expect(req.headers.authorization).toBe('Bearer token-123');

      res.statusCode = 200;
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({ ok: true }));
    }, servers);

    const result = await httpClient({
      config: new ServiceClientConfig({
        serviceId: 'users',
        baseUrl: server.baseUrl,
        redactedSummary: 'users@local',
        authProvider: async (operation) => {
          expect(operation.operationId).toBe('auth-check');
          return { authorization: 'Bearer token-123' };
        },
      }),
      request: new ServiceRequest({
        operationId: 'auth-check',
        method: 'GET',
        path: '/users',
      }),
      decoder: (value) => value as Record<string, unknown>,
    });

    expect(result.isSuccess).toBe(true);
    expect(result.value.data.ok).toBe(true);
  });

  it('returns a timeout failure when the request exceeds the configured timeout', async () => {
    const server = await startServer(async (_req, res) => {
      await new Promise((resolve) => setTimeout(resolve, 200));
      res.statusCode = 200;
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({ late: true }));
    }, servers);

    const result = await httpClient({
      config: new ServiceClientConfig({
        serviceId: 'slow',
        baseUrl: server.baseUrl,
        redactedSummary: 'slow@local',
        timeout: 20,
      }),
      request: new ServiceRequest({
        operationId: 'timeout-check',
        method: 'GET',
        path: '/slow',
      }),
    });

    expect(result.isFailure).toBe(true);
    expect(result.failure.category).toBe(ServiceFailureCategory.timeout);
    expect(result.failure.code).toBe('timeout');
    expect(result.failure.retryable).toBe(true);
  });

  it('normalizes auth failures for non-2xx HTTP responses', async () => {
    const server = await startServer(async (_req, res) => {
      res.statusCode = 401;
      res.end('missing token');
    }, servers);

    const result = await httpClient({
      config: new ServiceClientConfig({
        serviceId: 'auth',
        baseUrl: server.baseUrl,
        redactedSummary: 'auth@local',
      }),
      request: new ServiceRequest({
        operationId: 'unauthorized',
        method: 'GET',
        path: '/auth',
      }),
    });

    expect(result.isFailure).toBe(true);
    expect(result.failure.category).toBe(ServiceFailureCategory.auth);
    expect(result.failure.code).toBe('unauthorized');
    expect(result.failure.statusCode).toBe(401);
    expect(result.failure.details).toBe('missing token');
  });

  it('normalizes rate-limit failures for non-2xx HTTP responses', async () => {
    const server = await startServer(async (_req, res) => {
      res.statusCode = 429;
      res.end('retry later');
    }, servers);

    const result = await httpClient({
      config: new ServiceClientConfig({
        serviceId: 'rate-limit',
        baseUrl: server.baseUrl,
        redactedSummary: 'rate-limit@local',
      }),
      request: new ServiceRequest({
        operationId: 'too-many',
        method: 'GET',
        path: '/rate-limit',
      }),
    });

    expect(result.isFailure).toBe(true);
    expect(result.failure.category).toBe(ServiceFailureCategory.rateLimit);
    expect(result.failure.code).toBe('rate_limit');
    expect(result.failure.retryable).toBe(true);
    expect(result.failure.statusCode).toBe(429);
  });
});

describe('HttpServiceClient', () => {
  it('describes its config and closes cleanly', async () => {
    const client = new HttpServiceClient(
      new ServiceClientConfig({
        serviceId: 'users',
        baseUrl: 'https://example.test',
        redactedSummary: 'users@example',
      }),
    );

    expect(client.describe().serviceId).toBe('users');
    expect(client.describe().transportId).toBe('http');

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