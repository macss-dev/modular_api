"""Tests for cors_middleware — ASGI middleware that sets CORS headers."""

from __future__ import annotations

import pytest
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import PlainTextResponse
from starlette.routing import Route
from starlette.testclient import TestClient

from modular_api.middlewares.cors import cors_middleware


# ── Helpers ───────────────────────────────────────────────────


async def _echo_endpoint(request: Request) -> PlainTextResponse:
    return PlainTextResponse("ok")


def _build_app(**cors_options: object) -> TestClient:
    """Build a Starlette app with CORS middleware and a single /echo route."""
    app = Starlette(routes=[Route("/echo", _echo_endpoint)])
    cls = cors_middleware(**cors_options)
    app.add_middleware(cls)
    return TestClient(app)


# ── Default CORS headers ─────────────────────────────────────


class TestCorsDefaultHeaders:
    """cors_middleware sets correct Access-Control-* headers by default."""

    def test_allow_origin_default_wildcard(self) -> None:
        client = _build_app()
        response = client.get("/echo")
        assert response.headers["access-control-allow-origin"] == "*"

    def test_allow_methods_default(self) -> None:
        client = _build_app()
        response = client.get("/echo")
        assert "GET" in response.headers["access-control-allow-methods"]
        assert "POST" in response.headers["access-control-allow-methods"]
        assert "OPTIONS" in response.headers["access-control-allow-methods"]

    def test_allow_headers_default(self) -> None:
        client = _build_app()
        response = client.get("/echo")
        assert "Content-Type" in response.headers["access-control-allow-headers"]
        assert "Authorization" in response.headers["access-control-allow-headers"]

    def test_headers_present_on_non_options_request(self) -> None:
        client = _build_app()
        response = client.post("/echo")
        assert response.headers["access-control-allow-origin"] == "*"


# ── OPTIONS preflight ─────────────────────────────────────────


class TestCorsPreflightOptions:
    """OPTIONS requests return 204 with CORS headers."""

    def test_options_returns_204(self) -> None:
        client = _build_app()
        response = client.options("/echo")
        assert response.status_code == 204

    def test_options_includes_cors_headers(self) -> None:
        client = _build_app()
        response = client.options("/echo")
        assert "access-control-allow-origin" in response.headers
        assert "access-control-allow-methods" in response.headers
        assert "access-control-allow-headers" in response.headers

    def test_options_body_is_empty(self) -> None:
        client = _build_app()
        response = client.options("/echo")
        assert response.content == b""


# ── Configurable origin, methods, headers ─────────────────────


class TestCorsCustomOptions:
    """cors_middleware accepts configurable origin, methods, headers."""

    def test_custom_origin_string(self) -> None:
        client = _build_app(origin="https://example.com")
        response = client.get("/echo")
        assert response.headers["access-control-allow-origin"] == "https://example.com"

    def test_custom_origin_list(self) -> None:
        client = _build_app(origin=["https://a.com", "https://b.com"])
        response = client.get("/echo")
        assert response.headers["access-control-allow-origin"] == "https://a.com, https://b.com"

    def test_custom_methods(self) -> None:
        client = _build_app(methods="GET,POST")
        response = client.get("/echo")
        assert response.headers["access-control-allow-methods"] == "GET,POST"

    def test_custom_allowed_headers(self) -> None:
        client = _build_app(allowed_headers="X-Custom-Header")
        response = client.get("/echo")
        assert response.headers["access-control-allow-headers"] == "X-Custom-Header"
