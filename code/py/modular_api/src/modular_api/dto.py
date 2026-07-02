"""Web-safe DTO contract for modular_api.

Symmetry counterpart of the Dart ``package:modular_api/dto.dart`` and the
TypeScript ``@macss/modular-api/dto`` entry-points. Re-exports the runtime-free
surface for defining and validating request/response DTOs (``Input``,
``Output``, ``UseCaseException`` and pydantic's ``Field``) without importing the
Starlette server runtime. Import this from packages that only need the data
contract.
"""

from pydantic import Field

from modular_api.core.usecase import Input, Output
from modular_api.core.use_case_exception import UseCaseException

__all__ = ["Field", "Input", "Output", "UseCaseException"]
