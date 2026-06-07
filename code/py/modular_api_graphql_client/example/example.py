from modular_api_graphql_client import GraphqlRequest, ServiceClientConfig, graphql_client


def main() -> None:
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
        return

    print(result.failure.message)


if __name__ == "__main__":
    main()