"""RED — UseCaseHandler: Starlette endpoint factory for any UseCase."""

import json

import pytest
from starlette.applications import Starlette
from starlette.routing import Route
from starlette.testclient import TestClient

from modular_api.core.use_case_exception import UseCaseException
from modular_api.core.usecase import Input, Output, UseCase
from modular_api.core.usecase_handler import LOGGER_STATE_KEY, usecase_handler


# ── Stubs ─────────────────────────────────────────────────────────────────


class GreetInput(Input):
    name: str = ""


class GreetOutput(Output):
    greeting: str = ""

    @property
    def status_code(self) -> int:
        return 200


class GreetUseCase(UseCase[GreetInput, GreetOutput]):
    """Says hello — happy path."""

    def __init__(self, data: dict) -> None:
        self._input = GreetInput.from_json(data)

    @property
    def input(self) -> GreetInput:
        return self._input

    def validate(self) -> str | None:
        if not self._input.name:
            return "name is required"
        return None

    async def execute(self) -> GreetOutput:
        return GreetOutput(greeting=f"Hello, {self._input.name}!")


class FailingUseCase(UseCase[GreetInput, GreetOutput]):
    """Raises UseCaseException during execute."""

    def __init__(self, data: dict) -> None:
        self._input = GreetInput.from_json(data)

    @property
    def input(self) -> GreetInput:
        return self._input

    def validate(self) -> str | None:
        return None

    async def execute(self) -> GreetOutput:
        raise UseCaseException(
            status_code=409,
            message="Already exists",
            error_code="CONFLICT",
        )


class CrashingUseCase(UseCase[GreetInput, GreetOutput]):
    """Raises an unexpected error during execute."""

    def __init__(self, data: dict) -> None:
        self._input = GreetInput(name="x")

    @property
    def input(self) -> GreetInput:
        return self._input

    def validate(self) -> str | None:
        return None

    async def execute(self) -> GreetOutput:
        raise RuntimeError("disk on fire")


# ── Helpers ───────────────────────────────────────────────────────────────


def _app(*routes: Route) -> Starlette:
    return Starlette(routes=list(routes))


# ── Payload extraction ────────────────────────────────────────────────────


class TestPayloadExtraction:
    """POST/PUT/PATCH → JSON body; GET/DELETE → query params."""

    def test_post_extracts_json_body(self) -> None:
        app = _app(Route("/greet", usecase_handler(GreetUseCase), methods=["POST"]))
        client = TestClient(app)
        resp = client.post("/greet", json={"name": "World"})
        assert resp.status_code == 200
        assert resp.json()["greeting"] == "Hello, World!"

    def test_get_extracts_query_params(self) -> None:
        app = _app(Route("/greet", usecase_handler(GreetUseCase), methods=["GET"]))
        client = TestClient(app)
        resp = client.get("/greet?name=World")
        assert resp.status_code == 200
        assert resp.json()["greeting"] == "Hello, World!"

    def test_get_extracts_path_params(self) -> None:
        app = _app(Route("/greet/{name}", usecase_handler(GreetUseCase), methods=["GET"]))
        client = TestClient(app)
        resp = client.get("/greet/World")
        assert resp.status_code == 200
        assert resp.json()["greeting"] == "Hello, World!"


# ── UseCase lifecycle ─────────────────────────────────────────────────────


class TestUseCaseLifecycle:
    """validate → execute → respond with output.toJson + output.statusCode."""

    def test_validation_error_returns_400(self) -> None:
        app = _app(Route("/greet", usecase_handler(GreetUseCase), methods=["POST"]))
        client = TestClient(app)
        resp = client.post("/greet", json={"name": ""})
        assert resp.status_code == 400
        body = resp.json()
        assert body["error"] == "name is required"

    def test_use_case_exception_returns_custom_status(self) -> None:
        app = _app(Route("/fail", usecase_handler(FailingUseCase), methods=["POST"]))
        client = TestClient(app)
        resp = client.post("/fail", json={})
        assert resp.status_code == 409
        body = resp.json()
        assert body["error"] == "CONFLICT"
        assert body["message"] == "Already exists"

    def test_unhandled_exception_returns_500(self) -> None:
        app = _app(Route("/crash", usecase_handler(CrashingUseCase), methods=["POST"]))
        client = TestClient(app, raise_server_exceptions=False)
        resp = client.post("/crash", json={})
        assert resp.status_code == 500
        body = resp.json()
        assert body["error"] == "Internal server error"
        # Stack trace must NOT be exposed to the client.
        assert "disk on fire" not in json.dumps(body)

    def test_response_content_type_is_json(self) -> None:
        app = _app(Route("/greet", usecase_handler(GreetUseCase), methods=["POST"]))
        client = TestClient(app)
        resp = client.post("/greet", json={"name": "Ada"})
        assert "application/json" in resp.headers["content-type"]

    def test_non_dict_json_body_returns_400(self) -> None:
        """Bare JSON string like '"hello"' must return 400, not 500."""
        app = _app(Route("/greet", usecase_handler(GreetUseCase), methods=["POST"]))
        client = TestClient(app, raise_server_exceptions=False)
        resp = client.post(
            "/greet",
            content='"string"',
            headers={"content-type": "application/json"},
        )
        assert resp.status_code == 400
        assert "must be a JSON object" in resp.json()["error"]

    def test_logger_injected_from_request_state(self) -> None:
        """If logging middleware placed a logger in request.state, the handler injects it."""
        captured_loggers: list[object] = []

        class SpyUseCase(UseCase[GreetInput, GreetOutput]):
            def __init__(self, data: dict) -> None:
                self._input = GreetInput(name="x")

            @property
            def input(self) -> GreetInput:
                return self._input

            def validate(self) -> str | None:
                return None

            async def execute(self) -> GreetOutput:
                captured_loggers.append(self.logger)
                return GreetOutput(greeting="ok")

        # Middleware that fakes a logger in request.state
        from starlette.middleware import Middleware
        from starlette.middleware.base import BaseHTTPMiddleware

        class FakeLoggerMiddleware(BaseHTTPMiddleware):
            async def dispatch(self, request, call_next):
                setattr(request.state, LOGGER_STATE_KEY, "fake-logger")
                return await call_next(request)

        app = Starlette(
            routes=[Route("/spy", usecase_handler(SpyUseCase), methods=["POST"])],
            middleware=[Middleware(FakeLoggerMiddleware)],
        )
        client = TestClient(app)
        client.post("/spy", json={})
        assert captured_loggers == ["fake-logger"]


# ── Scoped-logger error integration (issue #7) ───────────────────────────


class TestScopedLoggerInErrorPaths:
    """Catch blocks must log through the request-scoped logger (with trace_id)
    instead of printing to stderr."""

    @staticmethod
    def _build_app_with_logger(
        factory,
        log_lines: list[str],
    ) -> Starlette:
        """App with logging middleware capturing output into log_lines."""
        from starlette.middleware import Middleware

        from modular_api.core.logger.logging_middleware import logging_middleware
        from modular_api.core.logger.logger import LogLevel

        mw_cls = logging_middleware(
            log_level=LogLevel.debug,
            service_name="test-svc",
            write_fn=lambda line: log_lines.append(line),
        )
        return Starlette(
            routes=[Route("/test", usecase_handler(factory), methods=["POST"])],
            middleware=[Middleware(mw_cls)],
        )

    def test_logs_use_case_exception_through_scoped_logger(self) -> None:
        log_lines: list[str] = []
        app = self._build_app_with_logger(FailingUseCase, log_lines)
        client = TestClient(app, raise_server_exceptions=False)
        resp = client.post(
            "/test",
            json={"name": "x"},
            headers={"X-Request-ID": "trace-py-uce-001"},
        )
        assert resp.status_code == 409

        error_logs = [
            json.loads(l)
            for l in log_lines
            if '"level": "error"' in l and "UseCaseException" in l
        ]
        assert len(error_logs) > 0, "expected error log from scoped logger"
        assert error_logs[0]["trace_id"] == "trace-py-uce-001"

    def test_logs_unexpected_error_through_scoped_logger(self) -> None:
        log_lines: list[str] = []
        app = self._build_app_with_logger(CrashingUseCase, log_lines)
        client = TestClient(app, raise_server_exceptions=False)
        resp = client.post(
            "/test",
            json={"name": "x"},
            headers={"X-Request-ID": "trace-py-crash-002"},
        )
        assert resp.status_code == 500

        error_logs = [
            json.loads(l)
            for l in log_lines
            if '"level": "error"' in l and "Unexpected error" in l
        ]
        assert len(error_logs) > 0, "expected error log from scoped logger"
        assert error_logs[0]["trace_id"] == "trace-py-crash-002"

    def test_does_not_throw_when_logger_unavailable(self) -> None:
        """When no logging middleware is present, catch blocks must not crash."""
        app = Starlette(
            routes=[Route("/test", usecase_handler(FailingUseCase), methods=["POST"])],
        )
        client = TestClient(app, raise_server_exceptions=False)
        resp = client.post("/test", json={"name": "x"})
        assert resp.status_code == 409
        assert resp.json()["message"] == "Already exists"
