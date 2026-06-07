# @macss/modular-api-graphql-client

Official MACSS outbound GraphQL client for TypeScript.

## Quick start

```ts
import { GraphqlRequest, ServiceClientConfig, graphqlClient } from '@macss/modular-api-graphql-client';

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
} else {
  console.error(result.failure.message);
}
```

## Current slice

- query-only GraphQL POST requests to `/graphql`
- normalized `GraphqlResponse<T>` with `data`, `errors`, `extensions`, and metadata
- persistent `GraphqlClient`
- one-shot `graphqlClient()` helper
- transport failures kept separate from GraphQL error envelopes