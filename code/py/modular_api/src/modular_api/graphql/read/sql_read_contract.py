"""Pure GraphQL SQL read contract for Stage 5."""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Iterable, Mapping


class SqlReadCommandPurpose(str, Enum):
    ITEM = "item"
    COLLECTION = "collection"
    RELATION_BATCH = "relation-batch"
    COUNT = "count"


@dataclass(frozen=True, slots=True)
class SqlParameter:
    name: str
    value: Any
    type: str | None = None


@dataclass(frozen=True, slots=True)
class SqlReadCommand:
    engine: str
    sql: str
    parameters: tuple[SqlParameter, ...]
    purpose: SqlReadCommandPurpose


@dataclass(frozen=True, slots=True)
class ReadExecutionContext:
    request_id: str | None = None
    principal: Any = None
    tenant_id: str | None = None
    telemetry: Any = None


@dataclass(frozen=True, slots=True)
class RowSet:
    rows: tuple[dict[str, Any], ...]
    row_count: int

    @staticmethod
    def normalize(raw_rows: Iterable[Mapping[object, Any]]) -> RowSet:
        rows: list[dict[str, Any]] = []
        for raw_row in raw_rows:
            row = {str(key): raw_row[key] for key in sorted(raw_row, key=lambda value: str(value))}
            rows.append(row)
        return RowSet(rows=tuple(rows), row_count=len(rows))


class ReadExecutor(ABC):
    @abstractmethod
    async def execute(self, command: SqlReadCommand, context: ReadExecutionContext) -> RowSet:
        raise NotImplementedError

    async def close(self) -> None:
        return None


class SqlFilterOperator(str, Enum):
    EQ = "eq"
    NE = "ne"
    IN_LIST = "inList"
    LT = "lt"
    LTE = "lte"
    GT = "gt"
    GTE = "gte"
    IS_NULL = "isNull"
    CONTAINS = "contains"
    STARTS_WITH = "startsWith"
    ENDS_WITH = "endsWith"


class SqlFilterNode:
    pass


@dataclass(frozen=True, slots=True)
class SqlFilterCondition(SqlFilterNode):
    field: str
    operator: SqlFilterOperator
    value: Any


class SqlFilterGroupKind(str, Enum):
    AND = "and"
    OR = "or"
    NOT = "not"


@dataclass(frozen=True, slots=True)
class SqlFilterGroup(SqlFilterNode):
    kind: SqlFilterGroupKind
    nodes: tuple[SqlFilterNode, ...]

    @staticmethod
    def and_(nodes: tuple[SqlFilterNode, ...]) -> SqlFilterGroup:
        return SqlFilterGroup(kind=SqlFilterGroupKind.AND, nodes=nodes)

    @staticmethod
    def or_(nodes: tuple[SqlFilterNode, ...]) -> SqlFilterGroup:
        return SqlFilterGroup(kind=SqlFilterGroupKind.OR, nodes=nodes)

    @staticmethod
    def not_(node: SqlFilterNode) -> SqlFilterGroup:
        return SqlFilterGroup(kind=SqlFilterGroupKind.NOT, nodes=(node,))


class SqlSortDirection(str, Enum):
    ASC = "asc"
    DESC = "desc"


@dataclass(frozen=True, slots=True)
class SqlOrderByClause:
    field: str
    direction: SqlSortDirection


@dataclass(frozen=True, slots=True)
class SqlPage:
    limit: int
    offset: int


@dataclass(frozen=True, slots=True)
class SqlItemSelection:
    object_id: str
    projected_fields: tuple[str, ...]
    key: dict[str, Any]


@dataclass(frozen=True, slots=True)
class SqlCollectionSelection:
    object_id: str
    projected_fields: tuple[str, ...]
    filter: SqlFilterNode | None = None
    order_by: tuple[SqlOrderByClause, ...] = ()
    page: SqlPage | None = None


@dataclass(frozen=True, slots=True)
class SqlCountSelection:
    object_id: str
    filter: SqlFilterNode | None = None


@dataclass(frozen=True, slots=True)
class SqlRelationBatchSelection:
    source_object_id: str
    relation_name: str
    projected_fields: tuple[str, ...]
    parent_keys: tuple[dict[str, Any], ...]