# modular_api_rest_client

Official MACSS outbound REST client for Dart.

## Quick start

```dart
import 'package:modular_api_rest_client/modular_api_rest_client.dart';

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
} else {
  print(result.failure.message);
}
```

## Current slice

- normalized `ServiceResult<T>` and `ServiceFailure`
- persistent `HttpServiceClient`
- one-shot `httpClient()` helper
- explicit request metadata via `ServiceRequest`
- JSON-first response decoding and HTTP metadata preservation