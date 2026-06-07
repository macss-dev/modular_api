"""SQL Server metadata reader for Stage 1 GraphQL physical model introspection."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any, Callable, cast

if TYPE_CHECKING:
    import pyodbc

from modular_api.graphql.sqlserver.physical_model import (
    PhysicalCatalog,
    PhysicalField,
    PhysicalObject,
    PhysicalObjectKind,
    PhysicalRelationSeed,
)
from modular_api.graphql.sqlserver.sql_server_connection_settings import (
    SqlServerConnectionSettings,
)

ConnectFn = Callable[..., Any]


class SqlServerMetadataReader:
    def __init__(
        self,
        connection: SqlServerConnectionSettings,
        connect: ConnectFn | None = None,
    ) -> None:
        self._connection = connection
        self._connect = connect

    def introspect(self, schema_names: set[str] | tuple[str, ...] | list[str] | None = None) -> PhysicalCatalog:
        normalized_schema_names = tuple(sorted(schema_names or ()))
        connect = self._connect or _load_pyodbc_connect()
        connection = connect(self._connection.connection_string(), timeout=5)
        try:
            cursor = connection.cursor()
            objects_by_id = _load_objects(cursor, normalized_schema_names)
            _load_fields(cursor, normalized_schema_names, objects_by_id)
            _load_identity_fields(cursor, normalized_schema_names, objects_by_id)
            _load_relations(cursor, normalized_schema_names, objects_by_id)

            objects = tuple(
                _build_physical_object(object_)
                for object_ in sorted(objects_by_id.values(), key=lambda item: item.id)
            )
            return PhysicalCatalog(objects=objects)
        finally:
            connection.close()


@dataclass(slots=True)
class _MutablePhysicalObject:
    id: str
    kind: PhysicalObjectKind
    schema_name: str
    object_name: str
    identity_fields: list[str] = field(default_factory=list)
    fields: list[PhysicalField] = field(default_factory=list)
    relations: list[PhysicalRelationSeed] = field(default_factory=list)


@dataclass(slots=True)
class _MutableRelation:
    name: str
    source_object_id: str
    target_object_id: str
    source_fields: list[str] = field(default_factory=list)
    target_fields: list[str] = field(default_factory=list)


def _load_objects(
    cursor: Any,
    schema_names: tuple[str, ...],
) -> dict[str, _MutablePhysicalObject]:
    rows = _run_metadata_query(
        cursor,
        label="SQL Server objects",
        query=f"""
SELECT
  s.name AS schema_name,
  o.name AS object_name,
  CASE o.type
    WHEN 'U' THEN 'table'
    WHEN 'V' THEN 'view'
  END AS object_kind
FROM sys.objects AS o
INNER JOIN sys.schemas AS s
  ON s.schema_id = o.schema_id
WHERE o.type IN ('U', 'V'){_schema_filter_clause('s.name', schema_names)}
ORDER BY s.name, o.name;
""",
    )

    objects_by_id: dict[str, _MutablePhysicalObject] = {}
    for row in rows:
        schema_name = _read_string(row, "schema_name")
        object_name = _read_string(row, "object_name")
        object_id = f"{schema_name}.{object_name}"
        objects_by_id[object_id] = _MutablePhysicalObject(
            id=object_id,
            kind=_parse_object_kind(_read_string(row, "object_kind")),
            schema_name=schema_name,
            object_name=object_name,
        )

    return objects_by_id


def _load_fields(
    cursor: Any,
    schema_names: tuple[str, ...],
    objects_by_id: dict[str, _MutablePhysicalObject],
) -> None:
    rows = _run_metadata_query(
        cursor,
        label="SQL Server columns",
        query=f"""
SELECT
  s.name AS schema_name,
  o.name AS object_name,
  c.name AS column_name,
  TYPE_NAME(c.user_type_id) AS type_name,
  CAST(c.max_length AS INT) AS max_length,
  CAST(c.precision AS INT) AS precision,
  CAST(c.scale AS INT) AS scale,
  CAST(c.is_nullable AS INT) AS is_nullable
FROM sys.objects AS o
INNER JOIN sys.schemas AS s
  ON s.schema_id = o.schema_id
INNER JOIN sys.columns AS c
  ON c.object_id = o.object_id
WHERE o.type IN ('U', 'V'){_schema_filter_clause('s.name', schema_names)}
ORDER BY s.name, o.name, c.column_id;
""",
    )

    for row in rows:
        object_ = _require_object(objects_by_id, row)
        object_.fields.append(
            PhysicalField(
                column=_read_string(row, "column_name"),
                native_type=_format_native_type(
                    type_name=_read_string(row, "type_name"),
                    max_length=_read_int(row, "max_length"),
                    precision=_read_int(row, "precision"),
                    scale=_read_int(row, "scale"),
                ),
                nullable=_read_bool(row, "is_nullable"),
            )
        )


def _load_identity_fields(
    cursor: Any,
    schema_names: tuple[str, ...],
    objects_by_id: dict[str, _MutablePhysicalObject],
) -> None:
    rows = _run_metadata_query(
        cursor,
        label="SQL Server identity fields",
        query=f"""
SELECT
  s.name AS schema_name,
  o.name AS object_name,
  c.name AS column_name
FROM sys.objects AS o
INNER JOIN sys.schemas AS s
  ON s.schema_id = o.schema_id
INNER JOIN sys.key_constraints AS kc
  ON kc.parent_object_id = o.object_id
 AND kc.type = 'PK'
INNER JOIN sys.index_columns AS ic
  ON ic.object_id = kc.parent_object_id
 AND ic.index_id = kc.unique_index_id
INNER JOIN sys.columns AS c
  ON c.object_id = ic.object_id
 AND c.column_id = ic.column_id
WHERE o.type = 'U'{_schema_filter_clause('s.name', schema_names)}
ORDER BY s.name, o.name, ic.key_ordinal;
""",
    )

    for row in rows:
        object_ = _require_object(objects_by_id, row)
        object_.identity_fields.append(_read_string(row, "column_name"))


def _load_relations(
    cursor: Any,
    schema_names: tuple[str, ...],
    objects_by_id: dict[str, _MutablePhysicalObject],
) -> None:
    rows = _run_metadata_query(
        cursor,
        label="SQL Server foreign keys",
        query=f"""
SELECT
  source_schema.name AS source_schema_name,
  source_object.name AS source_object_name,
  fk.name AS constraint_name,
  source_column.name AS source_column_name,
  target_schema.name AS target_schema_name,
  target_object.name AS target_object_name,
  target_column.name AS target_column_name
FROM sys.foreign_keys AS fk
INNER JOIN sys.foreign_key_columns AS fkc
  ON fkc.constraint_object_id = fk.object_id
INNER JOIN sys.objects AS source_object
  ON source_object.object_id = fk.parent_object_id
INNER JOIN sys.schemas AS source_schema
  ON source_schema.schema_id = source_object.schema_id
INNER JOIN sys.columns AS source_column
  ON source_column.object_id = source_object.object_id
 AND source_column.column_id = fkc.parent_column_id
INNER JOIN sys.objects AS target_object
  ON target_object.object_id = fk.referenced_object_id
INNER JOIN sys.schemas AS target_schema
  ON target_schema.schema_id = target_object.schema_id
INNER JOIN sys.columns AS target_column
  ON target_column.object_id = target_object.object_id
 AND target_column.column_id = fkc.referenced_column_id
WHERE source_object.type = 'U'{_schema_filter_clause('source_schema.name', schema_names)}
ORDER BY source_schema.name, source_object.name, fk.name, fkc.constraint_column_id;
""",
    )

    relations_by_key: dict[str, _MutableRelation] = {}
    for row in rows:
        source_object_id = f"{_read_string(row, 'source_schema_name')}.{_read_string(row, 'source_object_name')}"
        target_object_id = f"{_read_string(row, 'target_schema_name')}.{_read_string(row, 'target_object_name')}"
        constraint_name = _read_string(row, "constraint_name")
        relation_key = f"{source_object_id}|{constraint_name}|{target_object_id}"
        relation = relations_by_key.setdefault(
            relation_key,
            _MutableRelation(
                name=constraint_name,
                source_object_id=source_object_id,
                target_object_id=target_object_id,
            ),
        )
        relation.source_fields.append(_read_string(row, "source_column_name"))
        relation.target_fields.append(_read_string(row, "target_column_name"))

    for relation in relations_by_key.values():
        source_object = objects_by_id.get(relation.source_object_id)
        if source_object is None:
            raise RuntimeError(
                f"Missing source object for relation {relation.name}: {relation.source_object_id}"
            )

        source_object.relations.append(
            PhysicalRelationSeed(
                name=relation.name,
                source_object_id=relation.source_object_id,
                target_object_id=relation.target_object_id,
                source_fields=tuple(relation.source_fields),
                target_fields=tuple(relation.target_fields),
            )
        )


def _load_pyodbc_connect() -> ConnectFn:
    try:
        import pyodbc
    except ModuleNotFoundError as error:
        raise RuntimeError(
            'SqlServerMetadataReader requires the optional "pyodbc" package. '
            'Install it to use SQL Server introspection.'
        ) from error

    return cast(ConnectFn, pyodbc.connect)


def _run_metadata_query(
    cursor: Any,
    *,
    label: str,
    query: str,
) -> list[Any]:
    try:
        return list(cursor.execute(query).fetchall())
    except Exception as error:
        raise RuntimeError(f"Failed to load {label}: {error}") from error


def _build_physical_object(object_: _MutablePhysicalObject) -> PhysicalObject:
    return PhysicalObject(
        id=object_.id,
        kind=object_.kind,
        schema_name=object_.schema_name,
        object_name=object_.object_name,
        identity_fields=tuple(object_.identity_fields),
        fields=tuple(object_.fields),
        relations=tuple(object_.relations),
    )


def _require_object(
    objects_by_id: dict[str, _MutablePhysicalObject],
    row: Any,
) -> _MutablePhysicalObject:
    schema_name = _read_string(row, "schema_name")
    object_name = _read_string(row, "object_name")
    object_id = f"{schema_name}.{object_name}"
    try:
        return objects_by_id[object_id]
    except KeyError as error:
        raise RuntimeError(f"Object not loaded before metadata expansion: {object_id}") from error


def _parse_object_kind(value: str) -> PhysicalObjectKind:
    if value == PhysicalObjectKind.TABLE.value:
        return PhysicalObjectKind.TABLE
    if value == PhysicalObjectKind.VIEW.value:
        return PhysicalObjectKind.VIEW
    raise RuntimeError(f"Unsupported SQL Server object kind: {value}")


def _schema_filter_clause(column: str, schema_names: tuple[str, ...]) -> str:
    if not schema_names:
        return ""

    values = ", ".join(
        "N'{}'".format(schema_name.replace("'", "''"))
        for schema_name in schema_names
    )
    return f" AND {column} IN ({values})"


def _read_string(row: Any, key: str) -> str:
    value = _read_value(row, key)
    if value is None:
        raise RuntimeError(f"Expected non-null value for {key}")
    return str(value)


def _read_int(row: Any, key: str) -> int:
    value = _read_value(row, key)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    try:
        return int(str(value))
    except ValueError as error:
        raise RuntimeError(f"Expected integer value for {key}, got {value}") from error


def _read_bool(row: Any, key: str) -> bool:
    value = _read_value(row, key)
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return int(value) != 0

    normalized = str(value).strip().lower()
    if normalized in {"1", "true"}:
        return True
    if normalized in {"0", "false"}:
        return False
    raise RuntimeError(f"Expected boolean value for {key}, got {value}")


def _read_value(row: Any, key: str) -> Any:
    if hasattr(row, key):
        return getattr(row, key)

    row_mapping = getattr(row, "cursor_description", None)
    if row_mapping is not None:
        for index, column in enumerate(row_mapping):
            column_name = str(column[0])
            if column_name.lower() == key.lower():
                return row[index]

    raise RuntimeError(f"Missing expected SQL Server metadata column: {key}")


def _format_native_type(*, type_name: str, max_length: int, precision: int, scale: int) -> str:
    normalized = type_name.lower()
    if normalized in {"nvarchar", "nchar"}:
        length = "max" if max_length == -1 else str(max_length // 2)
        return f"{type_name}({length})"
    if normalized in {"varchar", "char", "varbinary", "binary"}:
        length = "max" if max_length == -1 else str(max_length)
        return f"{type_name}({length})"
    if normalized in {"decimal", "numeric"}:
        return f"{type_name}({precision},{scale})"
    if normalized in {"datetime2", "datetimeoffset", "time"}:
        return f"{type_name}({scale})"
    return type_name