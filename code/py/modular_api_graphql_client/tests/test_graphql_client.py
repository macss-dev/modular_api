from __future__ import annotations

import json
import threading
import time
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from modular_api_graphql_client import (
    GraphqlClient,
    GraphqlRequest,
    ServiceClientConfig,
    ServiceFailureCategory,
    graphql_client,
)


@dataclass(slots=True)
class _ServerHandle:
    base_url: str
    server: ThreadingHTTPServer
    thread: threading.Thread

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


def test_graphql_client_sends_a_post_request_and_decodes_the_envelope() -> None:
    def handler(request: BaseHTTPRequestHandler) -> None:
        assert request.command == "POST"
        assert request.path == "/graphql"
        assert request.headers["x-default"] == "package"
        assert request.headers["x-request"] == "test"

        content_length = int(request.headers.get("Content-Length", "0"))
        payload = json.loads(request.rfile.read(content_length).decode("utf-8"))
        assert payload["query"] == "query GetUsers { users { id } }"
        assert payload["operationName"] == "GetUsers"
        assert payload["variables"] == {"limit": 10}

        request.send_response(200)
        request.send_header("Content-Type", "application/json")
        request.send_header("X-Request-Id", "req-graphql-1")
        request.end_headers()
        request.wfile.write(
            json.dumps(
                {
                    "data": {"users": [{"id": "1"}]},
                    "extensions": {"traceId": "trace-1"},
                }
            ).encode("utf-8")
        )

    server = _start_server(handler)
    try:
        result = graphql_client(
            config=ServiceClientConfig(
                service_id="users-graphql",
                base_url=server.base_url,
                redacted_summary="users-graphql@local",
                default_headers={"x-default": "package"},
            ),
            request=GraphqlRequest(
                operation_id="users.query",
                document="query GetUsers { users { id } }",
                operation_name="GetUsers",
                variables={"limit": 10},
                headers={"x-request": "test"},
            ),
            decoder=lambda value: dict(value or {}),
        )

        assert result.is_success is True
        assert result.value.data == {"users": [{"id": "1"}]}
        assert result.value.errors == []
        assert result.value.extensions == {"traceId": "trace-1"}
        assert result.value.metadata.status_code == 200
        assert result.value.metadata.transport_id == "graphql"
        assert result.value.metadata.request_id == "req-graphql-1"
    finally:
        server.close()


def test_graphql_client_preserves_graphql_errors_without_transport_collapse() -> None:
    def handler(request: BaseHTTPRequestHandler) -> None:
        _drain_request_body(request)
        request.send_response(200)
        request.send_header("Content-Type", "application/json")
        request.end_headers()
        request.wfile.write(
            json.dumps(
                {
                    "data": None,
                    "errors": [
                        {
                            "message": "Field users is not available",
                            "path": ["users"],
                            "extensions": {"code": "FIELD_UNAVAILABLE"},
                        }
                    ],
                }
            ).encode("utf-8")
        )

    server = _start_server(handler)
    try:
        result = graphql_client(
            config=ServiceClientConfig(
                service_id="users-graphql",
                base_url=server.base_url,
                redacted_summary="users-graphql@local",
            ),
            request=GraphqlRequest(
                operation_id="users.error",
                document="query Broken { users }",
            ),
        )

        assert result.is_success is True
        assert result.value.data is None
        assert len(result.value.errors) == 1
        assert result.value.errors[0].message == "Field users is not available"
        assert result.value.errors[0].path == ["users"]
        assert result.value.errors[0].extensions == {"code": "FIELD_UNAVAILABLE"}
    finally:
        server.close()


def test_graphql_client_injects_auth_headers_from_the_auth_provider() -> None:
    def handler(request: BaseHTTPRequestHandler) -> None:
        assert request.headers["authorization"] == "Bearer token-123"
        _drain_request_body(request)
        request.send_response(200)
        request.send_header("Content-Type", "application/json")
        request.end_headers()
        request.wfile.write(json.dumps({"data": {"ok": True}}).encode("utf-8"))

    server = _start_server(handler)
    try:
        result = graphql_client(
            config=ServiceClientConfig(
                service_id="users-graphql",
                base_url=server.base_url,
                redacted_summary="users-graphql@local",
                auth_provider=lambda operation: {"authorization": "Bearer token-123"},
            ),
            request=GraphqlRequest(
                operation_id="users.auth",
                document="query Viewer { viewer { id } }",
            ),
            decoder=lambda value: dict(value or {}),
        )

        assert result.is_success is True
        assert result.value.data == {"ok": True}
    finally:
        server.close()


def test_graphql_client_returns_a_timeout_failure_when_the_request_exceeds_timeout() -> None:
    def handler(request: BaseHTTPRequestHandler) -> None:
        _drain_request_body(request)
        time.sleep(0.2)
        request.send_response(200)
        request.send_header("Content-Type", "application/json")
        request.end_headers()
        request.wfile.write(json.dumps({"data": {"late": True}}).encode("utf-8"))

    server = _start_server(handler)
    try:
        result = graphql_client(
            config=ServiceClientConfig(
                service_id="slow-graphql",
                base_url=server.base_url,
                redacted_summary="slow-graphql@local",
                timeout=0.02,
            ),
            request=GraphqlRequest(
                operation_id="users.timeout",
                document="query Slow { slow }",
            ),
        )

        assert result.is_failure is True
        assert result.failure.category is ServiceFailureCategory.TIMEOUT
        assert result.failure.code == "timeout"
        assert result.failure.retryable is True
    finally:
        server.close()


def test_graphql_client_keeps_transport_failures_separate_from_graphql_envelopes() -> None:
    def handler(request: BaseHTTPRequestHandler) -> None:
        _drain_request_body(request)
        request.send_response(401)
        request.end_headers()
        request.wfile.write(b"missing token")

    server = _start_server(handler)
    try:
        result = graphql_client(
            config=ServiceClientConfig(
                service_id="users-graphql",
                base_url=server.base_url,
                redacted_summary="users-graphql@local",
            ),
            request=GraphqlRequest(
                operation_id="users.transport",
                document="query Viewer { viewer { id } }",
            ),
        )

        assert result.is_failure is True
        assert result.failure.category is ServiceFailureCategory.AUTH
        assert result.failure.code == "unauthorized"
        assert result.failure.status_code == 401
    finally:
        server.close()


def test_graphql_client_rejects_mutation_documents_in_v1() -> None:
    result = graphql_client(
        config=ServiceClientConfig(
            service_id="users-graphql",
            base_url="https://example.test",
            redacted_summary="users-graphql@example",
        ),
        request=GraphqlRequest(
            operation_id="users.mutation",
            document="mutation UpdateUser { updateUser(id: 1) { id } }",
        ),
    )

    assert result.is_failure is True
    assert result.failure.category is ServiceFailureCategory.GRAPHQL
    assert result.failure.code == "mutation_not_supported"


def test_graphql_client_describes_its_config_and_closes_cleanly() -> None:
    client = GraphqlClient(
        ServiceClientConfig(
            service_id="users-graphql",
            base_url="https://example.test",
            redacted_summary="users-graphql@example",
        )
    )

    assert client.describe().service_id == "users-graphql"
    assert client.describe().transport_id == "graphql"

    closed = client.close()
    assert closed.is_success is True


def _start_server(handler):
    class _Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:  # noqa: N802
            handler(self)

        def log_message(self, format: str, *args) -> None:  # noqa: A003
            return None

    server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return _ServerHandle(
        base_url=f"http://127.0.0.1:{server.server_address[1]}",
        server=server,
        thread=thread,
    )


def _drain_request_body(request: BaseHTTPRequestHandler) -> None:
    content_length = int(request.headers.get("Content-Length", "0"))
    if content_length > 0:
        request.rfile.read(content_length)