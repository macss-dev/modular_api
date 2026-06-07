"""In-memory registry of all registered use cases.

Populated by ``ModuleBuilder.usecase()`` at startup. Consumed by
``build_openapi_spec()`` to generate the OpenAPI 3.0 specification
from the registered routes.

Mirror of ``_ApiRegistry`` / ``UseCaseRegistration`` in Dart and
``ApiRegistry`` / ``UseCaseRegistration`` in TypeScript.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable

from modular_api.core.usecase import Input, Output, UseCase

# Type alias — same as in usecase_handler.py.
UseCaseFactory = Callable[[dict[str, Any]], UseCase[Any, Any]]


@dataclass
class UseCaseDocMeta:
    """Optional OpenAPI documentation metadata attached to a use case."""

    summary: str | None = None
    description: str | None = None
    tags: list[str] | None = None


@dataclass
class UseCaseRegistration:
    """One registered route: everything the OpenAPI generator needs.

    Populated by ``ModuleBuilder.usecase()`` so the spec builder can
    iterate ``api_registry.routes`` and produce paths, schemas, and
    operation metadata without touching the live router.
    """

    module: str
    command: str  # route segment and operationId root, e.g. 'hello-world'
    method: str  # uppercase: "POST" | "GET" | "PUT" | "PATCH" | "DELETE"
    path: str  # e.g. "/api/v1/greetings/hello-world"
    factory: UseCaseFactory
    schemas: dict[str, dict[str, Any]] = field(default_factory=dict)
    doc: UseCaseDocMeta | None = None


class ApiRegistry:
    """Container for all registered use-case routes.

    Provides ``clear()`` to reset state between tests — the same
    pattern used in Dart and TypeScript implementations.
    """

    def __init__(self) -> None:
        self.routes: list[UseCaseRegistration] = []

    def clear(self) -> None:
        """Remove all registered routes (safe for test teardown)."""
        self.routes.clear()


# Module-level singleton — shared across the application.
api_registry = ApiRegistry()
