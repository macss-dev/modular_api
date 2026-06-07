import 'package:modular_api_graphql_client/modular_api_graphql_client.dart';

Future<void> main() async {
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
    return;
  }

  print(result.failure.message);
}