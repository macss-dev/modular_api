"""Normalized SQL Server physical metadata model for GraphQL catalog construction."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class PhysicalObjectKind(str, Enum):
    TABLE = "table"
    VIEW = "view"


@dataclass(frozen=True, slots=True)
class PhysicalField:
    column: str
    native_type: str
    nullable: bool


@dataclass(frozen=True, slots=True)
class PhysicalRelationSeed:
    name: str
    source_object_id: str
    target_object_id: str
    source_fields: tuple[str, ...]
    target_fields: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class PhysicalObject:
    id: str
    kind: PhysicalObjectKind
    schema_name: str
    object_name: str
    identity_fields: tuple[str, ...]
    fields: tuple[PhysicalField, ...]
    relations: tuple[PhysicalRelationSeed, ...]


@dataclass(frozen=True, slots=True)
class PhysicalCatalog:
    objects: tuple[PhysicalObject, ...]