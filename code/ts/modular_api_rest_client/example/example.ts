import { ServiceClientConfig, ServiceRequest, httpClient } from '../src';

async function main(): Promise<void> {
  const result = await httpClient<Record<string, unknown>>({
    config: new ServiceClientConfig({
      serviceId: 'users',
      baseUrl: 'https://api.example.test',
      redactedSummary: 'users@example',
      defaultHeaders: { accept: 'application/json' },
    }),
    request: new ServiceRequest({
      operationId: 'users.list',
      method: 'GET',
      path: '/users',
    }),
    decoder: (value) => value as Record<string, unknown>,
  });

  if (result.isSuccess) {
    console.log(result.value.data);
    return;
  }

  console.error(result.failure.message);
}

void main();