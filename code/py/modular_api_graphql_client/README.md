# macss-modular-api-graphql-client

Official MACSS outbound GraphQL client for Python.

## Quick start

```python
from modular_api_graphql_client import GraphqlRequest, ServiceClientConfig, graphql_client

result = graphql_client(
    config=ServiceClientConfig(
        service_id="users-graphql",
        base_url="https://api.example.test",
        redacted_summary="users-graphql@example",
        default_headers={"accept": "application/json"},
    ),
    request=GraphqlRequest(
        operation_id="users.query",
        document="query GetUsers { users { id } }",
        operation_name="GetUsers",
    ),
    decoder=lambda value: dict(value or {}),
)

if result.is_success:
    print(result.value.data)
    print(result.value.errors)
else:
    print(result.failure.message)
```

## Current slice

- query-only GraphQL POST requests to `/graphql`
- normalized `GraphqlResponse[T]` with `data`, `errors`, `extensions`, and metadata
- persistent `GraphqlClient`
- one-shot `graphql_client()` helper
- transport failures kept separate from GraphQL error envelopes