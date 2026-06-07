# modular_api_graphql_client

Official MACSS outbound GraphQL client for Dart.

## Quick start

```dart
import 'package:modular_api_graphql_client/modular_api_graphql_client.dart';

final result = await graphqlClient<Map<String, Object?>>(
  config: ServiceClientConfig(
    serviceId: 'users-graphql',
    baseUrl: Uri.parse('https://api.example.test'),
    redactedSummary: 'users-graphql@example',
    defaultHeaders: const {'accept': 'application/json'},
  ),
  request: const GraphqlRequest(
    operationId: 'users.query',
    document: 'query GetUsers { users { id } }',
    operationName: 'GetUsers',
  ),
  decoder: (json) => Map<String, Object?>.from(json as Map),
);

if (result.isSuccess) {
  print(result.value.data);
  print(result.value.errors);
} else {
  print(result.failure.message);
}
```

## Current slice

- query-only GraphQL POST requests to `/graphql`
- normalized `GraphqlResponse<T>` with `data`, `errors`, `extensions`, and metadata
- persistent `GraphqlClient`
- one-shot `graphqlClient()` helper
- transport failures kept separate from GraphQL error envelopes