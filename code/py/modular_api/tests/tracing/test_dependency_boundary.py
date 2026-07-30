"""Guards the dependency boundary that ADR-0005 (as amended, A1 and A2) rests on.

Core depends on the OpenTelemetry **API** — which is no-op when no SDK is
configured, so a consumer who never enables tracing pays nothing — and never on
an OpenTelemetry **SDK**, an exporter, gRPC or protobuf. Those belong to the
application, which supplies a configured ``TracerProvider`` through
``TracingOptions``.

The Dart and TypeScript counterparts are
``test/tracing/dependency_boundary_test.dart`` and
``test/tracing/dependencyBoundary.test.ts``. Same assertions, idiomatic
implementation.

Two deliberate details, shared with the TypeScript version:

- The manifest is the subject, not the installed environment. A package can be
  present in site-packages as somebody else's transitive dependency, which proves
  nothing about what this project declares.
- Only ``[project].dependencies`` is checked for the SDK prohibition. An SDK entry
  under ``optional-dependencies.dev`` is legitimate: it does not ship to
  consumers, and the official in-memory span exporter used by tests lives there.
"""

from __future__ import annotations

import re
import tomllib
from pathlib import Path

import pytest

_PYPROJECT = Path(__file__).resolve().parents[2] / "pyproject.toml"

_FORBIDDEN_PREFIXES = (
    "opentelemetry-sdk",
    "opentelemetry-exporter",
    "grpcio",
    "protobuf",
)


def _requirement_name(requirement: str) -> str:
    """Strip version specifiers and extras from a PEP 508 requirement string."""
    return re.split(r"[<>=!~\[\s;]", requirement, maxsplit=1)[0].strip().lower()


@pytest.fixture(scope="module")
def runtime_dependencies() -> list[str]:
    manifest = tomllib.loads(_PYPROJECT.read_text(encoding="utf-8"))
    return list(manifest["project"]["dependencies"])


def test_core_declares_the_opentelemetry_api(runtime_dependencies: list[str]) -> None:
    names = {_requirement_name(requirement) for requirement in runtime_dependencies}

    assert "opentelemetry-api" in names, (
        "core instruments against the OTel API (ADR-0005 A1); without it there is "
        "no span contract to instrument with"
    )


def test_core_declares_no_opentelemetry_sdk_exporter_grpc_or_protobuf(
    runtime_dependencies: list[str],
) -> None:
    offenders = [
        requirement
        for requirement in runtime_dependencies
        if _requirement_name(requirement).startswith(_FORBIDDEN_PREFIXES)
    ]

    assert offenders == [], (
        "the OTel SDK, its exporters, gRPC and protobuf are the application's "
        f"dependencies, not the framework's (ADR-0005 A2, A3). Found: {offenders}"
    )


def test_the_opentelemetry_api_dependency_is_bounded(
    runtime_dependencies: list[str],
) -> None:
    requirement = next(
        (
            candidate
            for candidate in runtime_dependencies
            if _requirement_name(candidate) == "opentelemetry-api"
        ),
        None,
    )

    # Fail with the same reason as the presence test rather than a StopIteration
    # traceback, so a removed dependency reads as one clear failure and not two
    # unrelated-looking ones.
    assert requirement is not None, (
        "opentelemetry-api is not declared at all (ADR-0005 A1)"
    )
    assert re.search(r"<\s*\d", requirement), (
        "the requirement needs an upper bound so a future major cannot arrive "
        f"silently. Found: {requirement!r}"
    )
