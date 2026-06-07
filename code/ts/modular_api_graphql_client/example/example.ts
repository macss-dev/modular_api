import { GraphqlRequest, ServiceClientConfig, graphqlClient } from '../src';

async function main(): Promise<void> {
  const result = await graphqlClient<Record<string, unknown>>({
    config: new ServiceClientConfig({
      serviceId: 'users-graphql',
      baseUrl: 'https://api.example.test',
      redactedSummary: 'users-graphql@example',
      defaultHeaders: { accept: 'application/json' },
    }),
    request: new GraphqlRequest({
      operationId: 'users.query',
      document: 'query GetUsers { users { id } }',
      operationName: 'GetUsers',
    }),
    decoder: (value) => value as Record<string, unknown>,
  });

  if (result.isSuccess) {
    console.log(result.value.data);
    console.log(result.value.errors);
    return;
  }

  console.error(result.failure.message);
}

void main();