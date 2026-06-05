from __future__ import annotations

from modular_api import HealthCheck, HealthCheckResult, HealthStatus


class AlwaysPassHealthCheck(HealthCheck):
    @property
    def name(self) -> str:
        return "example"

    async def check(self) -> HealthCheckResult:
        return HealthCheckResult(status=HealthStatus.PASS)
