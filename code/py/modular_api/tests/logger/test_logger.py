"""Tests for LogLevel, ModularLogger protocol, and RequestScopedLogger."""

from __future__ import annotations

import json
import time

from modular_api.core.logger.logger import (
    LogLevel,
    RequestScopedLogger,
)


# ── LogLevel enum ───────────────────────────────────────────────────


class TestLogLevel:
    def test_has_exactly_8_members(self) -> None:
        assert len(LogLevel) == 8

    def test_values_map_to_rfc5424_numeric_severity(self) -> None:
        assert LogLevel.emergency.value == 0
        assert LogLevel.alert.value == 1
        assert LogLevel.critical.value == 2
        assert LogLevel.error.value == 3
        assert LogLevel.warning.value == 4
        assert LogLevel.notice.value == 5
        assert LogLevel.info.value == 6
        assert LogLevel.debug.value == 7

    def test_name_returns_lowercase_string(self) -> None:
        assert LogLevel.emergency.name == "emergency"
        assert LogLevel.alert.name == "alert"
        assert LogLevel.critical.name == "critical"
        assert LogLevel.error.name == "error"
        assert LogLevel.warning.name == "warning"
        assert LogLevel.notice.name == "notice"
        assert LogLevel.info.name == "info"
        assert LogLevel.debug.name == "debug"


# ── RequestScopedLogger — filtering ────────────────────────────────


class TestLoggerFiltering:
    def _capture_logger(
        self, log_level: LogLevel
    ) -> tuple[RequestScopedLogger, list[str]]:
        lines: list[str] = []
        logger = RequestScopedLogger(
            trace_id="trace-1",
            log_level=log_level,
            service_name="test-svc",
            write_fn=lines.append,
        )
        return logger, lines

    def test_warning_level_emits_emergency_through_warning(self) -> None:
        logger, lines = self._capture_logger(LogLevel.warning)
        logger.emergency("e0")
        logger.alert("a1")
        logger.critical("c2")
        logger.error("e3")
        logger.warning("w4")
        assert len(lines) == 5

    def test_warning_level_suppresses_notice_info_debug(self) -> None:
        logger, lines = self._capture_logger(LogLevel.warning)
        logger.notice("n5")
        logger.info("i6")
        logger.debug("d7")
        assert len(lines) == 0

    def test_debug_level_emits_all_8_levels(self) -> None:
        logger, lines = self._capture_logger(LogLevel.debug)
        logger.emergency("e0")
        logger.alert("a1")
        logger.critical("c2")
        logger.error("e3")
        logger.warning("w4")
        logger.notice("n5")
        logger.info("i6")
        logger.debug("d7")
        assert len(lines) == 8

    def test_emergency_level_emits_only_emergency(self) -> None:
        logger, lines = self._capture_logger(LogLevel.emergency)
        logger.emergency("msg")
        logger.alert("msg")
        logger.critical("msg")
        logger.error("msg")
        logger.warning("msg")
        logger.notice("msg")
        logger.info("msg")
        logger.debug("msg")
        assert len(lines) == 1


# ── RequestScopedLogger — JSON format ──────────────────────────────


class TestLoggerJsonFormat:
    def _log_one(self, method: str = "info", **kwargs: object) -> dict[str, object]:
        lines: list[str] = []
        logger = RequestScopedLogger(
            trace_id="trace-abc",
            log_level=LogLevel.debug,
            service_name="my-api",
            write_fn=lines.append,
        )
        getattr(logger, method)("test message", **kwargs)
        return json.loads(lines[0])

    def test_each_log_is_valid_json(self) -> None:
        entry = self._log_one()
        assert isinstance(entry, dict)

    def test_contains_mandatory_fields(self) -> None:
        entry = self._log_one()
        for key in ("ts", "level", "severity", "msg", "service", "trace_id"):
            assert key in entry, f"Missing key: {key}"

    def test_ts_is_float_unix_timestamp(self) -> None:
        before = time.time()
        entry = self._log_one()
        after = time.time()
        ts = entry["ts"]
        assert isinstance(ts, float)
        assert before <= ts <= after + 0.01

    def test_level_is_lowercase_string(self) -> None:
        lines: list[str] = []
        logger = RequestScopedLogger(
            trace_id="t", log_level=LogLevel.debug,
            service_name="s", write_fn=lines.append,
        )
        logger.warning("warn test")
        entry = json.loads(lines[0])
        assert entry["level"] == "warning"

    def test_severity_matches_rfc5424_value(self) -> None:
        lines: list[str] = []
        logger = RequestScopedLogger(
            trace_id="t", log_level=LogLevel.debug,
            service_name="s", write_fn=lines.append,
        )
        logger.error("error test")
        entry = json.loads(lines[0])
        assert entry["severity"] == 3

    def test_msg_contains_provided_message(self) -> None:
        entry = self._log_one()
        assert entry["msg"] == "test message"

    def test_service_contains_configured_name(self) -> None:
        entry = self._log_one()
        assert entry["service"] == "my-api"

    def test_trace_id_included(self) -> None:
        entry = self._log_one()
        assert entry["trace_id"] == "trace-abc"

    def test_fields_included_when_provided(self) -> None:
        entry = self._log_one(fields={"userId": "u123", "active": True})
        assert entry["fields"] == {"userId": "u123", "active": True}

    def test_fields_absent_when_not_provided(self) -> None:
        entry = self._log_one()
        assert "fields" not in entry

    def test_each_level_produces_correct_pair(self) -> None:
        levels = [
            ("emergency", 0), ("alert", 1), ("critical", 2), ("error", 3),
            ("warning", 4), ("notice", 5), ("info", 6), ("debug", 7),
        ]
        for name, severity in levels:
            lines: list[str] = []
            logger = RequestScopedLogger(
                trace_id="t", log_level=LogLevel.debug,
                service_name="s", write_fn=lines.append,
            )
            getattr(logger, name)("msg")
            entry = json.loads(lines[0])
            assert entry["level"] == name, f"Expected level '{name}', got '{entry['level']}'"
            assert entry["severity"] == severity


# ── RequestScopedLogger — logResponse status mapping ───────────────


class TestLogResponseStatusMapping:
    def _log_response(self, status_code: int) -> dict[str, object]:
        lines: list[str] = []
        logger = RequestScopedLogger(
            trace_id="t", log_level=LogLevel.debug,
            service_name="s", write_fn=lines.append,
        )
        logger.log_response(
            method="GET", route="/test",
            status_code=status_code, duration_ms=1.5,
        )
        return json.loads(lines[0])

    def test_5xx_maps_to_error(self) -> None:
        entry = self._log_response(500)
        assert entry["level"] == "error"

    def test_4xx_maps_to_warning(self) -> None:
        entry = self._log_response(404)
        assert entry["level"] == "warning"

    def test_2xx_maps_to_info(self) -> None:
        entry = self._log_response(200)
        assert entry["level"] == "info"

    def test_1xx_maps_to_notice(self) -> None:
        entry = self._log_response(101)
        assert entry["level"] == "notice"

    def test_log_response_includes_extra_fields(self) -> None:
        entry = self._log_response(200)
        assert entry["method"] == "GET"
        assert entry["route"] == "/test"
        assert entry["status"] == 200
        assert entry["duration_ms"] == 1.5

    def test_log_request_emits_info(self) -> None:
        lines: list[str] = []
        logger = RequestScopedLogger(
            trace_id="t", log_level=LogLevel.debug,
            service_name="s", write_fn=lines.append,
        )
        logger.log_request(method="POST", route="/api/hello")
        entry = json.loads(lines[0])
        assert entry["level"] == "info"
        assert entry["msg"] == "request received"
        assert entry["method"] == "POST"
        assert entry["route"] == "/api/hello"

    def test_log_unhandled_exception(self) -> None:
        lines: list[str] = []
        logger = RequestScopedLogger(
            trace_id="t", log_level=LogLevel.debug,
            service_name="s", write_fn=lines.append,
        )
        logger.log_unhandled_exception(route="/api/fail", duration_ms=2.0)
        entry = json.loads(lines[0])
        assert entry["level"] == "error"
        assert entry["msg"] == "unhandled exception"
        assert entry["status"] == 500
