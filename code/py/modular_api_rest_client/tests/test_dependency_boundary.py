"""Guards the dependency boundary for a satellite package (runbook D21).

This package does **not** depend on ``macss-modular-api``, so it cannot inherit the
OpenTelemetry API transitively and must declare it itself. What it must never declare as a
runtime dependency is an OTel SDK, an exporter, grpcio or protobuf: those belong to the
application (ADR-0005 A2).

``optional-dependencies`` may carry them, and does — the in-memory exporter is needed to
observe instrumentation at all, since the API alone produces no-op spans (D22).
"""

from __future__ import annotations

import re
import tomllib
from pathlib import Path

import pytest

_PYPROJECT = Path(__file__).resolve().parents[1] / "pyproject.toml"

_FORBIDDEN_PREFIXES = (
    "opentelemetry-sdk",
    "opentelemetry-exporter",
    "grpcio",
    "protobuf",
)


def _requirement_name(requirement: str) -> str:
    return re.split(r"[<>=!~\[\s;]", requirement, maxsplit=1)[0].strip().lower()


@pytest.fixture(scope="module")
def runtime_dependencies() -> list[str]:
    manifest = tomllib.loads(_PYPROJECT.read_text(encoding="utf-8"))
    return list(manifest["project"]["dependencies"])


def test_declares_the_opentelemetry_api_directly(runtime_dependencies: list[str]) -> None:
    names = {_requirement_name(r) for r in runtime_dependencies}

    assert "opentelemetry-api" in names, (
        "this package does not depend on macss-modular-api, so the API cannot arrive "
        "transitively (D21)"
    )


def test_declares_no_sdk_exporter_grpc_or_protobuf(
    runtime_dependencies: list[str],
) -> None:
    offenders = [
        r
        for r in runtime_dependencies
        if _requirement_name(r).startswith(_FORBIDDEN_PREFIXES)
    ]

    assert offenders == [], (
        f"those belong to the application, not the framework (A2). Found: {offenders}"
    )


def test_the_api_requirement_is_bounded(runtime_dependencies: list[str]) -> None:
    requirement = next(
        (r for r in runtime_dependencies if _requirement_name(r) == "opentelemetry-api"),
        None,
    )

    assert requirement is not None, "opentelemetry-api is not declared at all (D21)"
    assert re.search(r"<\s*\d", requirement), (
        f"needs an upper bound so a future major cannot arrive silently. Found: {requirement!r}"
    )
