from __future__ import annotations

import re

from modular_api import Field, Input, Output, UseCase


# ── Input DTO ─────────────────────────────────────────────────


class CurrentTimeInput(Input):
    tz: str | None = Field(
        default=None,
        description="Timezone offset (e.g. utc-5, utc+3, utc)",
        examples=["utc-5"],
    )


# ── Output DTO ────────────────────────────────────────────────


class CurrentTimeOutput(Output):
    datetime: str = Field(
        description="ISO 8601 datetime at the requested offset",
        examples=["2026-03-14T07:00:00"],
    )
    offset: int = Field(description="UTC offset in hours", examples=[-5])

    @property
    def status_code(self) -> int:
        return 200


# ── UseCase ───────────────────────────────────────────────────

_OFFSET_RE = re.compile(r"^utc([+-]\d{1,2})$", re.IGNORECASE)


class CurrentTime(UseCase[CurrentTimeInput, CurrentTimeOutput]):
    def __init__(self, input_dto: CurrentTimeInput) -> None:
        self._input = input_dto

    @property
    def input(self) -> CurrentTimeInput:
        return self._input

    @classmethod
    def from_json(cls, json: dict[str, object]) -> CurrentTime:
        return cls(CurrentTimeInput.from_json(json))

    def validate(self) -> str | None:
        if not self.input.tz:
            return None
        offset = self._parse_offset(self.input.tz)
        if offset is None:
            return "invalid timezone format, use utc, utc-5, utc+3"
        if not -12 <= offset <= 14:
            return "offset must be between -12 and +14"
        return None

    async def execute(self) -> CurrentTimeOutput:
        from datetime import datetime, timezone, timedelta

        now_utc = datetime.now(tz=timezone.utc)
        if self.input.tz:
            offset_hours = self._parse_offset(self.input.tz)  # already validated
        else:
            # Fall back to system local offset
            local_now = datetime.now().astimezone()
            offset_hours = int(local_now.utcoffset().total_seconds() // 3600)  # type: ignore[union-attr]

        adjusted = now_utc + timedelta(hours=offset_hours)  # type: ignore[arg-type]
        iso = adjusted.strftime("%Y-%m-%dT%H:%M:%S")

        self.logger.info(f"Time requested for offset {offset_hours}")
        return CurrentTimeOutput(datetime=iso, offset=offset_hours)  # type: ignore[arg-type]

    @staticmethod
    def _parse_offset(tz: str) -> int | None:
        """Parses 'utc-5', 'utc+3', 'utc' into an integer offset. Returns None on bad format."""
        lower = tz.strip().lower()
        if lower == "utc":
            return 0
        match = _OFFSET_RE.match(lower)
        if not match:
            return None
        return int(match.group(1))
