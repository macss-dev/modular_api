"""The ``Typing :: Typed`` classifier and the ``py.typed`` marker must agree.

**They did not.** All five Python packages declare ``Typing :: Typed``, which tells PyPI and anyone
reading the metadata that the package ships type information. Only ``macss-modular-api`` actually
shipped the ``py.typed`` marker. Under PEP 561 a package without that file is treated as **untyped**
regardless of how thoroughly its source is annotated — every symbol a consumer imports becomes
``Any``, silently. The classifier was a promise four of the five wheels did not keep.

Verified against built wheels before writing this, not inferred: ``python -m build --wheel`` on
``macss-modular-api-postgres`` produced an archive with no ``py.typed`` entry at all.

This test lives in the core package but checks all five, because the failure is a *repo-wide*
inconsistency and a per-package test would have to be added five times to catch it once.
"""

from __future__ import annotations

import tomllib
from pathlib import Path

import pytest

_PY_ROOT = Path(__file__).resolve().parents[2]

_PACKAGES = (
    "modular_api",
    "modular_api_rest_client",
    "modular_api_postgres",
    "modular_api_graphql_client",
    "modular_api_sqlserver",
)


def _manifest(package: str) -> dict[str, object]:
    return tomllib.loads((_PY_ROOT / package / "pyproject.toml").read_text(encoding="utf-8"))


def _import_package_dir(package: str) -> Path:
    """The directory that becomes the importable package, i.e. the one holding ``__init__.py``.

    Found rather than assumed: the distribution name, the directory under ``src/`` and the import name
    are three different strings in this repo, and an ``egg-info`` directory sits alongside.
    """
    source = _PY_ROOT / package / "src"
    candidates = [child for child in source.iterdir() if (child / "__init__.py").is_file()]
    assert len(candidates) == 1, f"expected exactly one importable package under {source}"
    return candidates[0]


@pytest.mark.parametrize("package", _PACKAGES)
def test_a_package_claiming_to_be_typed_ships_the_marker(package: str) -> None:
    manifest = _manifest(package)
    project = manifest["project"]
    assert isinstance(project, dict)

    classifiers = [str(c) for c in project.get("classifiers", [])]
    claims_typed = "Typing :: Typed" in classifiers
    marker = _import_package_dir(package) / "py.typed"

    if claims_typed:
        assert marker.is_file(), (
            f"{package} declares the 'Typing :: Typed' classifier but ships no py.typed marker. "
            "Under PEP 561 a consumer's type checker treats it as untyped, so every annotation in "
            f"the source is discarded. Create {marker}."
        )
    else:
        assert not marker.is_file(), (
            f"{package} ships a py.typed marker but does not declare 'Typing :: Typed'. "
            "The metadata should say what the wheel does."
        )


@pytest.mark.parametrize("package", _PACKAGES)
def test_the_marker_is_inside_the_importable_package(package: str) -> None:
    # Not in `src/`, not in an `egg-info` directory, not next to `pyproject.toml`. PEP 561 looks for
    # `<package>/py.typed`, and a marker anywhere else lands in the wheel's `dist-info` — where no
    # type checker will look. That is the mistake this test was written after making.
    marker = _import_package_dir(package) / "py.typed"

    if marker.is_file():
        assert marker.parent.name != "src"
        assert not marker.parent.name.endswith(".egg-info")
        assert (marker.parent / "__init__.py").is_file()


def test_every_package_declares_the_typed_classifier() -> None:
    # Recorded as its own expectation rather than left implicit in the parametrized test above: all
    # five packages are fully annotated and all five should say so. If one legitimately should not,
    # this is the test to change, deliberately.
    missing = [
        package
        for package in _PACKAGES
        if "Typing :: Typed" not in [str(c) for c in (_manifest(package)["project"] or {}).get("classifiers", [])]  # type: ignore[union-attr]
    ]

    assert missing == [], f"these packages do not declare 'Typing :: Typed': {missing}"
