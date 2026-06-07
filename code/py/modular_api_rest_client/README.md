# macss-modular-api-rest-client

Official MACSS outbound REST client for Python.

## Quick start

```python
from modular_api_rest_client import ServiceClientConfig, ServiceRequest, http_client

result = http_client(
	config=ServiceClientConfig(
		service_id="users",
		base_url="https://api.example.test",
		redacted_summary="users@example",
		default_headers={"accept": "application/json"},
	),
	request=ServiceRequest(
		operation_id="users.list",
		method="GET",
		path="/users",
	),
)

if result.is_success:
	print(result.value.data)
else:
	print(result.failure.message)
```

## Current slice

- normalized `ServiceResult[T]` and `ServiceFailure`
- persistent `HttpServiceClient`
- one-shot `http_client()` helper
- explicit request metadata via `ServiceRequest`
- JSON-first response decoding and HTTP metadata preservation