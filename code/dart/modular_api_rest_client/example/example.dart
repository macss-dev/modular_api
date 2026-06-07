import 'package:modular_api_rest_client/modular_api_rest_client.dart';

Future<void> main() async {
  final result = await httpClient<Map<String, Object?>>(
    config: ServiceClientConfig(
      serviceId: 'users',
      baseUrl: Uri.parse('https://api.example.test'),
      redactedSummary: 'users@example',
      defaultHeaders: const {'accept': 'application/json'},
    ),
    request: const ServiceRequest(
      operationId: 'users.list',
      method: 'GET',
      path: '/users',
    ),
    decoder: (json) => Map<String, Object?>.from(json as Map),
  );

  if (result.isSuccess) {
    print(result.value.data);
    return;
  }

  print(result.failure.message);
}