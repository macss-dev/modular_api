"""Tests for HealthStatus, HealthCheckResult, and HealthCheck ABC."""

from __future__ import annotations

import pytest

from modular_api.core.health.health_check import (
    HealthCheck,
    HealthCheckResult,
    HealthStatus,
)


# ── HealthStatus enum ──────────────────────────────────────────────


class TestHealthStatus:
    def test_has_three_values(self) -> None:
        assert len(HealthStatus) == 3

    def test_severity_ordering(self) -> None:
        assert HealthStatus.PASS.value < HealthStatus.WARN.value < HealthStatus.FAIL.value

    def test_serializes_to_lowercase(self) -> None:
        assert HealthStatus.PASS.to_json() == "pass"
        assert HealthStatus.WARN.to_json() == "warn"
        assert HealthStatus.FAIL.to_json() == "fail"


# ── HealthCheckResult ──────────────────────────────────────────────


class TestHealthCheckResult:
    def test_stores_status(self) -> None:
        result = HealthCheckResult(status=HealthStatus.PASS)
        assert result.status == HealthStatus.PASS

    def test_optional_response_time_and_output(self) -> None:
        result = HealthCheckResult(status=HealthStatus.WARN, output="degraded")
        assert result.response_time is None
        assert result.output == "degraded"

    def test_with_response_time_returns_copy(self) -> None:
        original = HealthCheckResult(status=HealthStatus.PASS, output="ok")
        copy = original.with_response_time(42)
        assert copy.response_time == 42
        assert copy.status == HealthStatus.PASS
        assert copy.output == "ok"
        assert original.response_time is None  # original unchanged

    def test_to_json_minimal(self) -> None:
        result = HealthCheckResult(status=HealthStatus.PASS)
        j = result.to_json()
        assert j == {"status": "pass"}
        assert "responseTime" not in j
        assert "output" not in j

    def test_to_json_full(self) -> None:
        result = HealthCheckResult(
            status=HealthStatus.FAIL, response_time=150, output="timeout"
        )
        j = result.to_json()
        assert j == {"status": "fail", "responseTime": 150, "output": "timeout"}


# ── HealthCheck ABC ────────────────────────────────────────────────


class TestHealthCheck:
    def test_cannot_instantiate_directly(self) -> None:
        with pytest.raises(TypeError):
            HealthCheck()  # type: ignore[abstract]

    def test_default_timeout_is_5_seconds(self) -> None:
        class DummyCheck(HealthCheck):
            @property
            def name(self) -> str:
                return "dummy"

            async def check(self) -> HealthCheckResult:
                return HealthCheckResult(status=HealthStatus.PASS)

        hc = DummyCheck()
        assert hc.timeout == 5.0

    async def test_concrete_check_returns_result(self) -> None:
        class AlwaysPass(HealthCheck):
            @property
            def name(self) -> str:
                return "always-pass"

            async def check(self) -> HealthCheckResult:
                return HealthCheckResult(status=HealthStatus.PASS)

        hc = AlwaysPass()
        result = await hc.check()
        assert result.status == HealthStatus.PASS
