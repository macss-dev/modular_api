"""Tests for HealthService — aggregation, timeout, parallel execution."""

from __future__ import annotations

import asyncio

from modular_api.core.health.health_check import (
    HealthCheck,
    HealthCheckResult,
    HealthStatus,
)
from modular_api.core.health.health_service import HealthResponse, HealthService


# ── Stub health checks ─────────────────────────────────────────────


class AlwaysPassCheck(HealthCheck):
    @property
    def name(self) -> str:
        return "always-pass"

    async def check(self) -> HealthCheckResult:
        return HealthCheckResult(status=HealthStatus.PASS)


class AlwaysWarnCheck(HealthCheck):
    @property
    def name(self) -> str:
        return "always-warn"

    async def check(self) -> HealthCheckResult:
        return HealthCheckResult(status=HealthStatus.WARN, output="degraded")


class AlwaysFailCheck(HealthCheck):
    @property
    def name(self) -> str:
        return "always-fail"

    async def check(self) -> HealthCheckResult:
        return HealthCheckResult(status=HealthStatus.FAIL, output="down")


class SlowCheck(HealthCheck):
    """Times out by sleeping longer than its timeout."""

    @property
    def name(self) -> str:
        return "slow"

    @property
    def timeout(self) -> float:
        return 0.05  # 50ms

    async def check(self) -> HealthCheckResult:
        await asyncio.sleep(1.0)  # way over timeout
        return HealthCheckResult(status=HealthStatus.PASS)


class ExplodingCheck(HealthCheck):
    @property
    def name(self) -> str:
        return "exploding"

    async def check(self) -> HealthCheckResult:
        raise RuntimeError("boom")


# ── Tests ───────────────────────────────────────────────────────────


class TestHealthService:
    async def test_no_checks_returns_pass(self) -> None:
        svc = HealthService(version="1.0.0")
        resp = await svc.evaluate()
        assert resp.status == HealthStatus.PASS
        assert resp.http_status_code == 200
        assert resp.checks == {}

    async def test_single_passing_check(self) -> None:
        svc = HealthService(version="1.0.0")
        svc.add_health_check(AlwaysPassCheck())
        resp = await svc.evaluate()
        assert resp.status == HealthStatus.PASS
        assert resp.http_status_code == 200
        assert "always-pass" in resp.checks

    async def test_worst_status_wins_fail_over_pass(self) -> None:
        svc = HealthService(version="1.0.0")
        svc.add_health_check(AlwaysPassCheck())
        svc.add_health_check(AlwaysFailCheck())
        resp = await svc.evaluate()
        assert resp.status == HealthStatus.FAIL
        assert resp.http_status_code == 503

    async def test_worst_status_wins_warn_over_pass(self) -> None:
        svc = HealthService(version="1.0.0")
        svc.add_health_check(AlwaysPassCheck())
        svc.add_health_check(AlwaysWarnCheck())
        resp = await svc.evaluate()
        assert resp.status == HealthStatus.WARN
        assert resp.http_status_code == 200

    async def test_timed_out_check_reports_fail(self) -> None:
        svc = HealthService(version="1.0.0")
        svc.add_health_check(SlowCheck())
        resp = await svc.evaluate()
        assert resp.status == HealthStatus.FAIL
        assert "slow" in resp.checks
        assert resp.checks["slow"].status == HealthStatus.FAIL
        assert "timeout" in (resp.checks["slow"].output or "").lower()

    async def test_exception_in_check_reports_fail(self) -> None:
        svc = HealthService(version="1.0.0")
        svc.add_health_check(ExplodingCheck())
        resp = await svc.evaluate()
        assert resp.status == HealthStatus.FAIL
        assert resp.checks["exploding"].status == HealthStatus.FAIL

    async def test_response_time_is_measured(self) -> None:
        svc = HealthService(version="1.0.0")
        svc.add_health_check(AlwaysPassCheck())
        resp = await svc.evaluate()
        result = resp.checks["always-pass"]
        assert result.response_time is not None
        assert result.response_time >= 0


class TestHealthResponse:
    def test_to_json_includes_all_fields(self) -> None:
        resp = HealthResponse(
            status=HealthStatus.PASS,
            version="1.0.0",
            release_id="1.0.0-debug",
            checks={
                "db": HealthCheckResult(
                    status=HealthStatus.PASS, response_time=5
                )
            },
        )
        j = resp.to_json()
        assert j["status"] == "pass"
        assert j["version"] == "1.0.0"
        assert j["releaseId"] == "1.0.0-debug"
        assert "db" in j["checks"]

    def test_http_200_for_pass(self) -> None:
        resp = HealthResponse(
            status=HealthStatus.PASS, version="1", release_id="1", checks={}
        )
        assert resp.http_status_code == 200

    def test_http_200_for_warn(self) -> None:
        resp = HealthResponse(
            status=HealthStatus.WARN, version="1", release_id="1", checks={}
        )
        assert resp.http_status_code == 200

    def test_http_503_for_fail(self) -> None:
        resp = HealthResponse(
            status=HealthStatus.FAIL, version="1", release_id="1", checks={}
        )
        assert resp.http_status_code == 503
