"""Health check types following the IETF Health Check Response Format draft.

Spec: https://datatracker.ietf.org/doc/html/draft-inadarei-api-health-check

Status values: ``pass``, ``warn``, ``fail``.
HTTP mapping: 200 for pass/warn, 503 for fail.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from enum import IntEnum


class HealthStatus(IntEnum):
    """Health status values — ordered by severity (pass < warn < fail).

    The numeric value doubles as severity: higher = worse.
    This enables worst-status-wins aggregation via ``max()``.
    """

    PASS = 0
    WARN = 1
    FAIL = 2

    def to_json(self) -> str:
        """Serialize to the IETF-mandated lowercase string."""
        return self.name.lower()


class HealthCheckResult:
    """Result returned by a single :class:`HealthCheck`."""

    def __init__(
        self,
        *,
        status: HealthStatus,
        response_time: int | None = None,
        output: str | None = None,
    ) -> None:
        self.status = status
        self.response_time = response_time
        self.output = output

    def with_response_time(self, ms: int) -> HealthCheckResult:
        """Return a copy with a different response_time."""
        return HealthCheckResult(
            status=self.status,
            response_time=ms,
            output=self.output,
        )

    def to_json(self) -> dict[str, object]:
        """Serialize to the IETF JSON structure."""
        result: dict[str, object] = {"status": self.status.to_json()}
        if self.response_time is not None:
            result["responseTime"] = self.response_time
        if self.output is not None:
            result["output"] = self.output
        return result


class HealthCheck(ABC):
    """Abstract base for custom health checks.

    Implementors must provide ``name`` and ``check()``.
    Override ``timeout`` to change the default 5-second deadline.
    """

    @property
    @abstractmethod
    def name(self) -> str:
        """Display name used as the key in the ``checks`` map."""
        ...

    @property
    def timeout(self) -> float:
        """Maximum seconds allowed before the check is considered failed."""
        return 5.0

    @abstractmethod
    async def check(self) -> HealthCheckResult:
        """Execute the health check and return a result."""
        ...
