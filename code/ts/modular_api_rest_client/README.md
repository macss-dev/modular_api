# @macss/modular-api-rest-client

Official MACSS outbound REST client for TypeScript.

## Quick start

```ts
import { ServiceClientConfig, ServiceRequest, httpClient } from '@macss/modular-api-rest-client';

const result = await httpClient({
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
} else {
  console.error(result.failure.message);
}
```

## Current slice

- normalized `ServiceResult<T>` and `ServiceFailure`
- persistent `HttpServiceClient`
- one-shot `httpClient()` helper
- explicit request metadata via `ServiceRequest`
- JSON-first response decoding and HTTP metadata preservation