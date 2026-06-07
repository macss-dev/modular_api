from __future__ import annotations

import json
import threading
import time
import urllib.parse
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from modular_api_rest_client import (
    HttpServiceClient,
    ServiceClientConfig,
    ServiceFailureCategory,
    ServiceRequest,
    http_client,
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


def test_http_client_sends_a_get_request_decodes_json_and_preserves_metadata() -> None:
    def handler(request: BaseHTTPRequestHandler) -> None:
        parsed = urllib.parse.urlparse(request.path)
        query = urllib.parse.parse_qs(parsed.query)

        assert request.command == "GET"
        assert parsed.path == "/users"
        assert query["name"] == ["ana"]
        assert request.headers["x-default"] == "package"
        assert request.headers["x-request"] == "test"

        request.send_response(200)
        request.send_header("Content-Type", "application/json")
        request.send_header("X-Request-Id", "req-123")
        request.end_headers()
        request.wfile.write(json.dumps({"ok": True, "name": "Ana"}).encode("utf-8"))

    server = _start_server(handler)
    try:
        result = http_client(
            config=ServiceClientConfig(
                service_id="users",
                base_url=server.base_url,
                redacted_summary="users@local",
                default_headers={"x-default": "package"},
            ),
            request=ServiceRequest(
                operation_id="get-users",
                method="GET",
                path="/users",
                query={"name": "ana"},
                headers={"x-request": "test"},
            ),
            decoder=lambda value: dict(value),
        )

        assert result.is_success is True
        assert result.value.data["ok"] is True
        assert result.value.data["name"] == "Ana"
        assert result.value.metadata.status_code == 200
        assert result.value.metadata.transport_id == "http"
        assert result.value.metadata.request_id == "req-123"
        assert result.value.metadata.headers["x-request-id"] == "req-123"
    finally:
        server.close()


def test_http_client_returns_a_decode_failure_for_invalid_json_responses() -> None:
    def handler(request: BaseHTTPRequestHandler) -> None:
        request.send_response(200)
        request.send_header("Content-Type", "application/json")
        request.end_headers()
        request.wfile.write(b"{broken-json")

    server = _start_server(handler)
    try:
        result = http_client(
            config=ServiceClientConfig(
                service_id="broken",
                base_url=server.base_url,
                redacted_summary="broken@local",
            ),
            request=ServiceRequest(
                operation_id="decode-failure",
                method="GET",
                path="/broken",
            ),
        )

        assert result.is_failure is True
        assert result.failure.category is ServiceFailureCategory.DECODE
        assert result.failure.code == "invalid_json"
    finally:
        server.close()


def test_http_client_injects_auth_headers_from_the_auth_provider() -> None:
    def handler(request: BaseHTTPRequestHandler) -> None:
        assert request.headers["authorization"] == "Bearer token-123"

        request.send_response(200)
        request.send_header("Content-Type", "application/json")
        request.end_headers()
        request.wfile.write(json.dumps({"ok": True}).encode("utf-8"))

    server = _start_server(handler)
    try:
        result = http_client(
            config=ServiceClientConfig(
                service_id="users",
                base_url=server.base_url,
                redacted_summary="users@local",
                auth_provider=lambda operation: {"authorization": "Bearer token-123"},
            ),
            request=ServiceRequest(
                operation_id="auth-check",
                method="GET",
                path="/users",
            ),
            decoder=lambda value: dict(value),
        )

        assert result.is_success is True
        assert result.value.data["ok"] is True
    finally:
        server.close()


def test_http_client_returns_a_timeout_failure_when_the_request_exceeds_the_configured_timeout() -> None:
    def handler(request: BaseHTTPRequestHandler) -> None:
        time.sleep(0.2)
        request.send_response(200)
        request.send_header("Content-Type", "application/json")
        request.end_headers()
        request.wfile.write(json.dumps({"late": True}).encode("utf-8"))

    server = _start_server(handler)
    try:
        result = http_client(
            config=ServiceClientConfig(
                service_id="slow",
                base_url=server.base_url,
                redacted_summary="slow@local",
                timeout=0.02,
            ),
            request=ServiceRequest(
                operation_id="timeout-check",
                method="GET",
                path="/slow",
            ),
        )

        assert result.is_failure is True
        assert result.failure.category is ServiceFailureCategory.TIMEOUT
        assert result.failure.code == "timeout"
        assert result.failure.retryable is True
    finally:
        server.close()


def test_http_client_normalizes_auth_failures_for_non_2xx_http_responses() -> None:
    def handler(request: BaseHTTPRequestHandler) -> None:
        request.send_response(401)
        request.end_headers()
        request.wfile.write(b"missing token")

    server = _start_server(handler)
    try:
        result = http_client(
            config=ServiceClientConfig(
                service_id="auth",
                base_url=server.base_url,
                redacted_summary="auth@local",
            ),
            request=ServiceRequest(
                operation_id="unauthorized",
                method="GET",
                path="/auth",
            ),
        )

        assert result.is_failure is True
        assert result.failure.category is ServiceFailureCategory.AUTH
        assert result.failure.code == "unauthorized"
        assert result.failure.status_code == 401
        assert result.failure.details == "missing token"
    finally:
        server.close()


def test_http_client_normalizes_rate_limit_failures_for_non_2xx_http_responses() -> None:
    def handler(request: BaseHTTPRequestHandler) -> None:
        request.send_response(429)
        request.end_headers()
        request.wfile.write(b"retry later")

    server = _start_server(handler)
    try:
        result = http_client(
            config=ServiceClientConfig(
                service_id="rate-limit",
                base_url=server.base_url,
                redacted_summary="rate-limit@local",
            ),
            request=ServiceRequest(
                operation_id="too-many",
                method="GET",
                path="/rate-limit",
            ),
        )

        assert result.is_failure is True
        assert result.failure.category is ServiceFailureCategory.RATE_LIMIT
        assert result.failure.code == "rate_limit"
        assert result.failure.retryable is True
        assert result.failure.status_code == 429
    finally:
        server.close()


def test_http_service_client_describes_its_config_and_closes_cleanly() -> None:
    client = HttpServiceClient(
        ServiceClientConfig(
            service_id="users",
            base_url="https://example.test",
            redacted_summary="users@example",
        )
    )

    assert client.describe().service_id == "users"
    assert client.describe().transport_id == "http"

    closed = client.close()
    assert closed.is_success is True


def _start_server(handler):
    class _Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
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