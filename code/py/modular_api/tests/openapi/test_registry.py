"""Tests for ApiRegistry — in-memory route registry for OpenAPI generation."""

from __future__ import annotations

import pytest

from modular_api.core.registry import ApiRegistry, UseCaseDocMeta, UseCaseRegistration


# ── Fixtures ──────────────────────────────────────────────────

def _dummy_factory(json: dict) -> object:
    """Factory stub — never actually called in registry tests."""
    return object()


def _make_registration(**overrides: object) -> UseCaseRegistration:
    """Builds a UseCaseRegistration with sensible defaults, overridable per field."""
    defaults: dict = {
        "module": "users",
        "command": "create",
        "method": "POST",
        "path": "/api/users/create",
        "factory": _dummy_factory,
        "schemas": {"input": {"type": "object"}, "output": {"type": "object"}},
        "doc": None,
    }
    defaults.update(overrides)
    return UseCaseRegistration(**defaults)


# ── UseCaseRegistration dataclass ─────────────────────────────

class TestUseCaseRegistration:
    """UseCaseRegistration stores all metadata for a single registered route."""

    def test_fields_are_accessible(self) -> None:
        reg = _make_registration()
        assert reg.module == "users"
        assert reg.command == "create"
        assert reg.method == "POST"
        assert reg.path == "/api/users/create"
        assert reg.factory is _dummy_factory
        assert reg.schemas == {"input": {"type": "object"}, "output": {"type": "object"}}
        assert reg.doc is None

    def test_doc_metadata_is_stored(self) -> None:
        doc = UseCaseDocMeta(
            summary="Create a user",
            description="Creates a new user in the system",
            tags=["users"],
        )
        reg = _make_registration(doc=doc)
        assert reg.doc is not None
        assert reg.doc.summary == "Create a user"
        assert reg.doc.description == "Creates a new user in the system"
        assert reg.doc.tags == ["users"]


# ── ApiRegistry ───────────────────────────────────────────────

class TestApiRegistry:
    """ApiRegistry is the singleton-like container for all registered routes."""

    def test_starts_empty(self) -> None:
        registry = ApiRegistry()
        assert registry.routes == []

    def test_stores_registrations(self) -> None:
        registry = ApiRegistry()
        reg1 = _make_registration(command="create")
        reg2 = _make_registration(command="delete", method="DELETE", path="/api/users/delete")

        registry.routes.append(reg1)
        registry.routes.append(reg2)

        assert len(registry.routes) == 2
        assert registry.routes[0].command == "create"
        assert registry.routes[1].command == "delete"

    def test_clear_empties_all_routes(self) -> None:
        registry = ApiRegistry()
        registry.routes.append(_make_registration())
        registry.routes.append(_make_registration(command="list"))
        assert len(registry.routes) == 2

        registry.clear()
        assert registry.routes == []

    def test_clear_is_idempotent_on_empty(self) -> None:
        """Calling clear() on an already-empty registry does not raise."""
        registry = ApiRegistry()
        registry.clear()
        assert registry.routes == []


# ── Module-level singleton ────────────────────────────────────

class TestApiRegistrySingleton:
    """The module exposes a single ``api_registry`` instance used globally."""

    def test_module_singleton_exists(self) -> None:
        from modular_api.core.registry import api_registry

        assert isinstance(api_registry, ApiRegistry)

    def test_module_singleton_is_stable(self) -> None:
        """Two imports yield the same instance."""
        from modular_api.core.registry import api_registry as a
        from modular_api.core.registry import api_registry as b

        assert a is b
