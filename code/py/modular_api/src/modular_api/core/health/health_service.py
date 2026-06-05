"""Health service — aggregates checks, measures timing, worst-status-wins."""

from __future__ import annotations

import asyncio
import os
import time

from modular_api.core.health.health_check import (
    HealthCheck,
    HealthCheckResult,
    HealthStatus,
)


class HealthResponse:
    """Aggregated health response following the IETF Health Check Response Format."""

    def __init__(
        self,
        *,
        status: HealthStatus,
        version: str,
        release_id: str,
        checks: dict[str, HealthCheckResult],
    ) -> None:
        self.status = status
        self.version = version
        self.release_id = release_id
        self.checks = checks

    @property
    def http_status_code(self) -> int:
        """200 for pass/warn, 503 for fail — as expected by load balancers."""
        return 503 if self.status == HealthStatus.FAIL else 200

    def to_json(self) -> dict[str, object]:
        """Serialize to IETF-compliant JSON."""
        return {
            "status": self.status.to_json(),
            "version": self.version,
            "releaseId": self.release_id,
            "checks": {name: r.to_json() for name, r in self.checks.items()},
        }


class HealthService:
    """Manages and evaluates :class:`HealthCheck` instances.

    Checks run in parallel with per-check timeout.
    Overall status uses worst-status-wins aggregation: fail > warn > pass.
    """

    def __init__(self, *, version: str, release_id: str | None = None) -> None:
        self.version = version
        self.release_id = release_id or os.environ.get(
            "RELEASE_ID", f"{version}-debug"
        )
        self._checks: list[HealthCheck] = []

    def add_health_check(self, check: HealthCheck) -> None:
        """Register a health check to evaluate on each call to ``evaluate()``."""
        self._checks.append(check)

    async def evaluate(self) -> HealthResponse:
        """Execute all checks in parallel and return an aggregated response."""
        if not self._checks:
            return HealthResponse(
                status=HealthStatus.PASS,
                version=self.version,
                release_id=self.release_id,
                checks={},
            )

        entries = await asyncio.gather(
            *(self._run_check(c) for c in self._checks)
        )

        checks = dict(entries)
        worst = max(r.status for r in checks.values())

        return HealthResponse(
            status=HealthStatus(worst),
            version=self.version,
            release_id=self.release_id,
            checks=checks,
        )

    async def _run_check(
        self, check: HealthCheck
    ) -> tuple[str, HealthCheckResult]:
        """Run a single check with timeout and timing."""
        start = time.monotonic()
        try:
            result = await asyncio.wait_for(
                check.check(), timeout=check.timeout
            )
            elapsed_ms = int((time.monotonic() - start) * 1000)
            return check.name, result.with_response_time(elapsed_ms)
        except asyncio.TimeoutError:
            elapsed_ms = int((time.monotonic() - start) * 1000)
            return check.name, HealthCheckResult(
                status=HealthStatus.FAIL,
                response_time=elapsed_ms,
                output=f'Health check "{check.name}" timeout after {check.timeout}s',
            )
        except Exception as exc:
            elapsed_ms = int((time.monotonic() - start) * 1000)
            return check.name, HealthCheckResult(
                status=HealthStatus.FAIL,
                response_time=elapsed_ms,
                output=str(exc),
            )
