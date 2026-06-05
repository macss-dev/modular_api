"""Tests for health_handler — Starlette endpoint."""

from __future__ import annotations

import json

from starlette.testclient import TestClient
from starlette.applications import Starlette
from starlette.routing import Route

from modular_api.core.health.health_check import (
    HealthCheck,
    HealthCheckResult,
    HealthStatus,
)
from modular_api.core.health.health_handler import health_handler
from modular_api.core.health.health_service import HealthService


class AlwaysPassCheck(HealthCheck):
    @property
    def name(self) -> str:
        return "db"

    async def check(self) -> HealthCheckResult:
        return HealthCheckResult(status=HealthStatus.PASS)


class AlwaysFailCheck(HealthCheck):
    @property
    def name(self) -> str:
        return "cache"

    async def check(self) -> HealthCheckResult:
        return HealthCheckResult(status=HealthStatus.FAIL, output="unreachable")


def _app(service: HealthService) -> Starlette:
    handler = health_handler(service)
    return Starlette(routes=[Route("/health", handler)])


class TestHealthHandler:
    def test_returns_200_with_health_json_content_type(self) -> None:
        svc = HealthService(version="1.0.0")
        svc.add_health_check(AlwaysPassCheck())
        client = TestClient(_app(svc))

        resp = client.get("/health")
        assert resp.status_code == 200
        assert resp.headers["content-type"] == "application/health+json"

    def test_returns_503_when_check_fails(self) -> None:
        svc = HealthService(version="1.0.0")
        svc.add_health_check(AlwaysFailCheck())
        client = TestClient(_app(svc))

        resp = client.get("/health")
        assert resp.status_code == 503

    def test_response_body_is_valid_ietf_json(self) -> None:
        svc = HealthService(version="2.0.0", release_id="2.0.0-rc1")
        svc.add_health_check(AlwaysPassCheck())
        client = TestClient(_app(svc))

        resp = client.get("/health")
        body = resp.json()
        assert body["status"] == "pass"
        assert body["version"] == "2.0.0"
        assert body["releaseId"] == "2.0.0-rc1"
        assert "db" in body["checks"]
