"""RED — Logging middleware for Starlette: trace_id, structured JSON logs."""

import json

import pytest
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import PlainTextResponse, Response
from starlette.routing import Route
from starlette.testclient import TestClient

from modular_api.core.logger.logger import LogLevel, RequestScopedLogger
from modular_api.core.logger.logging_middleware import (
    LOGGER_STATE_KEY,
    logging_middleware,
)


# ── Helpers ───────────────────────────────────────────────────────────────


def _build_app(
    *,
    handler=None,
    excluded_routes: list[str] | None = None,
    log_level: LogLevel = LogLevel.debug,
) -> tuple[list[str], Starlette]:
    """Returns (captured_lines, app) for testing."""
    captured: list[str] = []

    def write_fn(line: str) -> None:
        captured.append(line)

    if handler is None:

        async def handler(request: Request) -> Response:
            return PlainTextResponse("ok")

    mw = logging_middleware(
        log_level=log_level,
        service_name="test-svc",
        excluded_routes=excluded_routes or [],
        write_fn=write_fn,
    )

    app = Starlette(routes=[
        Route("/api/test", handler, methods=["GET", "POST", "PUT"]),
        Route("/api/users/create", handler, methods=["POST"]),
        Route("/api/fail", handler, methods=["POST"]),
        Route("/health", handler, methods=["GET"]),
        Route("/metrics", handler, methods=["GET"]),
    ])
    app.add_middleware(mw)
    return captured, app


# ── trace_id ──────────────────────────────────────────────────────────────


class TestTraceId:
    """Generates or propagates X-Request-ID."""

    def test_generates_uuid_v4_when_header_absent(self) -> None:
        captured, app = _build_app()
        client = TestClient(app)
        client.get("/api/test")
        first = json.loads(captured[0])
        trace_id = first["trace_id"]
        import re
        assert re.match(
            r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
            trace_id,
        )

    def test_uses_x_request_id_header_when_present(self) -> None:
        captured, app = _build_app()
        client = TestClient(app)
        client.post("/api/test", headers={"X-Request-ID": "custom-trace-abc"})
        first = json.loads(captured[0])
        assert first["trace_id"] == "custom-trace-abc"

    def test_same_trace_id_in_request_and_response_logs(self) -> None:
        captured, app = _build_app()
        client = TestClient(app)
        client.get("/api/test")
        req_log = json.loads(captured[0])
        res_log = json.loads(captured[1])
        assert req_log["trace_id"] == res_log["trace_id"]

    def test_x_request_id_response_header(self) -> None:
        captured, app = _build_app()
        client = TestClient(app)
        resp = client.get("/api/test")
        assert "x-request-id" in resp.headers
        first = json.loads(captured[0])
        assert resp.headers["x-request-id"] == first["trace_id"]


# ── Request received log ─────────────────────────────────────────────────


class TestRequestReceivedLog:
    """First log line: 'request received' at info level."""

    def test_emits_request_received_as_first_log(self) -> None:
        captured, app = _build_app()
        client = TestClient(app)
        client.post("/api/users/create")
        first = json.loads(captured[0])
        assert first["msg"] == "request received"
        assert first["level"] == "info"
        assert first["severity"] == 6

    def test_includes_method_and_route(self) -> None:
        captured, app = _build_app()
        client = TestClient(app)
        client.post("/api/users/create")
        first = json.loads(captured[0])
        assert first["method"] == "POST"
        assert first["route"] == "/api/users/create"

    def test_includes_service_name(self) -> None:
        captured, app = _build_app()
        client = TestClient(app)
        client.get("/api/test")
        first = json.loads(captured[0])
        assert first["service"] == "test-svc"


# ── Request completed log ────────────────────────────────────────────────


class TestRequestCompletedLog:
    """Second log line: 'request completed' with status and duration."""

    def test_emits_request_completed_with_status_and_duration(self) -> None:
        captured, app = _build_app()
        client = TestClient(app)
        client.get("/api/test")
        last = json.loads(captured[-1])
        assert last["msg"] == "request completed"
        assert last["status"] == 200
        assert isinstance(last["duration_ms"], (int, float))
        assert last["duration_ms"] >= 0

    def test_includes_method_and_route(self) -> None:
        captured, app = _build_app()
        client = TestClient(app)
        client.put("/api/test")
        last = json.loads(captured[-1])
        assert last["method"] == "PUT"
        assert last["route"] == "/api/test"


# ── Status code → log level mapping ──────────────────────────────────────


class TestStatusCodeLogLevel:
    """Verify response log levels based on status code."""

    def test_2xx_maps_to_info(self) -> None:
        async def handler(request: Request) -> Response:
            return Response(status_code=201)

        captured, app = _build_app(handler=handler)
        client = TestClient(app)
        client.post("/api/test")
        last = json.loads(captured[-1])
        assert last["level"] == "info"

    def test_4xx_maps_to_warning(self) -> None:
        async def handler(request: Request) -> Response:
            return Response(status_code=400)

        captured, app = _build_app(handler=handler)
        client = TestClient(app)
        client.post("/api/test")
        last = json.loads(captured[-1])
        assert last["level"] == "warning"
        assert last["severity"] == 4

    def test_5xx_maps_to_error(self) -> None:
        async def handler(request: Request) -> Response:
            return Response(status_code=500)

        captured, app = _build_app(handler=handler)
        client = TestClient(app)
        client.post("/api/test")
        last = json.loads(captured[-1])
        assert last["level"] == "error"
        assert last["severity"] == 3


# ── Excluded routes ──────────────────────────────────────────────────────


class TestExcludedRoutes:
    """Requests to excluded paths produce no logs."""

    def test_health_not_logged_when_excluded(self) -> None:
        captured, app = _build_app(excluded_routes=["/health", "/metrics"])
        client = TestClient(app)
        client.get("/health")
        assert captured == []

    def test_metrics_not_logged_when_excluded(self) -> None:
        captured, app = _build_app(excluded_routes=["/health", "/metrics"])
        client = TestClient(app)
        client.get("/metrics")
        assert captured == []

    def test_non_excluded_routes_are_logged(self) -> None:
        captured, app = _build_app(excluded_routes=["/health", "/metrics"])
        client = TestClient(app)
        client.post("/api/users/create")
        assert len(captured) == 2  # request received + request completed


# ── Logger propagation ────────────────────────────────────────────────────


class TestLoggerPropagation:
    """Logger is placed in request.state for downstream handlers."""

    def test_logger_available_in_request_state(self) -> None:
        captured_logger: list[object] = []

        async def handler(request: Request) -> Response:
            captured_logger.append(getattr(request.state, LOGGER_STATE_KEY, None))
            return PlainTextResponse("ok")

        captured, app = _build_app(handler=handler)
        client = TestClient(app)
        client.get("/api/test")
        assert captured_logger[0] is not None
        assert isinstance(captured_logger[0], RequestScopedLogger)

    def test_logger_has_same_trace_id(self) -> None:
        captured_logger: list[RequestScopedLogger] = []

        async def handler(request: Request) -> Response:
            captured_logger.append(getattr(request.state, LOGGER_STATE_KEY))
            return PlainTextResponse("ok")

        captured, app = _build_app(handler=handler)
        client = TestClient(app)
        client.get("/api/test", headers={"X-Request-ID": "my-trace"})
        assert captured_logger[0].trace_id == "my-trace"
