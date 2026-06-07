from modular_api_rest_client import ServiceClientConfig, ServiceRequest, http_client


def main() -> None:
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
        return

    print(result.failure.message)


if __name__ == "__main__":
    main()