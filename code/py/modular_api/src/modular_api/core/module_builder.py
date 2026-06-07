"""Fluent builder that registers use cases on a Starlette Router.

Returned by ``ModularApi.module()`` inside the callback:

    api.module("users", lambda m: (
        m.usecase("create", CreateUser.from_json),
        m.usecase("list", ListUsers.from_json, method="GET"),
    ))

Each ``usecase()`` call mounts an endpoint on the module's Router
and stores metadata in ``api_registry`` for OpenAPI generation.

Mirror of ``ModuleBuilder`` in Dart and TypeScript.
"""

from __future__ import annotations

import inspect
import typing
from typing import Any, Callable

from starlette.routing import Route, Router

from modular_api.core.registry import (
    UseCaseDocMeta,
    UseCaseFactory,
    UseCaseRegistration,
    api_registry,
)
from modular_api.core.usecase import Input, Output, UseCase
from modular_api.core.usecase_handler import usecase_handler


def _get_return_type_hint(factory: Callable) -> type | None:  # noqa: ANN401
    """Extract the UseCase class from the factory callable.

    Our convention: factories are classmethods like ``HelloWorld.from_json``.
    A bound classmethod has ``__self__`` pointing to the class itself.
    """
    # Bound classmethod: StubUseCase.from_json → __self__ is StubUseCase
    owner = getattr(factory, "__self__", None)
    if isinstance(owner, type) and issubclass(owner, UseCase):
        return owner

    # Fallback: try return type hint resolution
    try:
        hints = typing.get_type_hints(factory)
        ret = hints.get("return")
        if isinstance(ret, type) and issubclass(ret, UseCase):
            return ret
    except Exception:
        pass

    return None


def _extract_dto_classes(usecase_cls: type) -> tuple[type | None, type | None]:
    """Walk a UseCase subclass's MRO to find its Input and Output type args.

    Given ``class HelloWorld(UseCase[HelloInput, HelloOutput])``, returns
    ``(HelloInput, HelloOutput)``.
    """
    input_cls: type | None = None
    output_cls: type | None = None

    for base in getattr(usecase_cls, "__orig_bases__", ()):
        origin = getattr(base, "__origin__", None)
        if origin is UseCase or (isinstance(origin, type) and issubclass(origin, UseCase)):
            args = getattr(base, "__args__", ())
            if len(args) >= 2:
                input_cls = args[0] if isinstance(args[0], type) else None
                output_cls = args[1] if isinstance(args[1], type) else None
            break

    return input_cls, output_cls


class ModuleBuilder:
    """Collects use cases for one module and mounts them on a Starlette Router.

    The builder provides a fluent API — every ``usecase()`` returns ``self``
    so multiple registrations can be chained.
    """

    def __init__(self, base_path: str, module_name: str) -> None:
        self._base_path = base_path
        self._module_name = module_name
        self._routes: list[Route] = []

    # ── Public API ────────────────────────────────────────────

    def usecase(
        self,
        command: str,
        factory: UseCaseFactory,
        *,
        method: str = "POST",
        summary: str | None = None,
        description: str | None = None,
    ) -> ModuleBuilder:
        """Register a use case as an HTTP endpoint on this module.

        ``command`` becomes the route segment and the OpenAPI operationId root.
        Convention: command, class name, and file name share the same root.
        Example: command ``'hello-world'`` → class ``HelloWorld`` → file ``hello_world.py``.

        Returns ``self`` for fluent chaining.
        """
        clean_command = command.strip().lstrip("/")
        method_upper = method.upper()
        full_path = f"{self._normalize_base(self._base_path)}/{self._module_name}/{clean_command}"

        # Mount endpoint on internal route list
        self._routes.append(
            Route(f"/{clean_command}", endpoint=usecase_handler(factory), methods=[method_upper]),
        )

        # Capture schemas via a dummy factory call (fail-safe)
        schemas = self._extract_schemas(factory)

        # Register metadata for OpenAPI generation
        doc = UseCaseDocMeta(
            summary=summary or f"Use case {clean_command} in module {self._module_name}",
            description=description or f"Auto-generated documentation for {clean_command}",
            tags=[self._module_name],
        )

        api_registry.routes.append(
            UseCaseRegistration(
                module=self._module_name,
                command=clean_command,
                method=method_upper,
                path=full_path,
                factory=factory,
                schemas=schemas,
                doc=doc,
            ),
        )

        return self

    def build_router(self) -> Router:
        """Create a Starlette Router containing all registered use-case routes."""
        return Router(routes=list(self._routes))

    # ── Private helpers ───────────────────────────────────────

    @staticmethod
    def _extract_schemas(factory: UseCaseFactory) -> dict[str, dict[str, Any]]:
        """Capture Input and Output schemas from a UseCase factory.

        Uses class-level extraction via ``to_schema()`` classmethod on BaseModel DTOs.
        Inspects the factory's type hints to find the Input/Output classes.
        """
        input_schema: dict[str, Any] = {}
        output_schema: dict[str, Any] = {}

        return_hint = _get_return_type_hint(factory)

        if return_hint is not None:
            input_cls, output_cls = _extract_dto_classes(return_hint)

            if input_cls is not None and hasattr(input_cls, "to_schema"):
                try:
                    input_schema = input_cls.to_schema()
                except Exception:
                    pass

            if output_cls is not None and hasattr(output_cls, "to_schema"):
                try:
                    output_schema = output_cls.to_schema()
                except Exception:
                    pass

        return {"input": input_schema, "output": output_schema}

    @staticmethod
    def _normalize_base(path: str) -> str:
        """Ensure base_path starts with '/' (or is empty)."""
        if not path:
            return ""
        return path if path.startswith("/") else f"/{path}"
