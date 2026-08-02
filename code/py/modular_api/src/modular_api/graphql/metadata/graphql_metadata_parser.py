"""GraphQL sidecar metadata parser for Stage 2 validation."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any, cast

import json5

from modular_api.graphql.sqlserver.physical_model import (
    PhysicalCatalog,
    PhysicalObjectKind,
)


class GraphqlMetadataSeverity(str, Enum):
    ERROR = "error"
    WARNING = "warning"


@dataclass(frozen=True, slots=True)
class GraphqlMetadataDiagnostic:
    severity: GraphqlMetadataSeverity
    code: str
    message: str
    object_id: str | None = None
    field: str | None = None


@dataclass(frozen=True, slots=True)
class GraphqlMetadataLimit:
    default_value: int
    max_value: int


@dataclass(frozen=True, slots=True)
class GraphqlFieldMetadata:
    hidden: bool = False
    sensitive: bool = False
    no_filter: bool = False
    no_sort: bool = False
    name: str | None = None


@dataclass(frozen=True, slots=True)
class GraphqlRelationMetadata:
    name: str
    cardinality: str
    target: str
    via: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class GraphqlObjectMetadata:
    publish: bool
    name: str | None = None
    key: tuple[str, ...] | None = None
    fields: dict[str, GraphqlFieldMetadata] | None = None
    relations: tuple[GraphqlRelationMetadata, ...] = ()
    limit: GraphqlMetadataLimit | None = None

    def __post_init__(self) -> None:
        if self.fields is None:
            object.__setattr__(self, "fields", {})


@dataclass(frozen=True, slots=True)
class GraphqlMetadataFile:
    version: int
    objects: dict[str, GraphqlObjectMetadata]
    schema: str | None = None
    defaults_limit: GraphqlMetadataLimit | None = None


@dataclass(frozen=True, slots=True)
class GraphqlMetadataParseResult:
    metadata: GraphqlMetadataFile | None
    diagnostics: tuple[GraphqlMetadataDiagnostic, ...]


class GraphqlMetadataParser:
    def parse(
        self,
        *,
        raw_jsonc: str,
        physical_catalog: PhysicalCatalog,
    ) -> GraphqlMetadataParseResult:
        diagnostics: list[GraphqlMetadataDiagnostic] = []
        physical_objects_by_id = {object_.id: object_ for object_ in physical_catalog.objects}

        try:
            # `json5` ships no type information, so everything it returns is implicitly Any and
            # that spread to every downstream read — over fifty diagnostics from this one line.
            # Declared `object` here and narrowed once below, which puts the untyped boundary in one
            # place instead of at every `.get`.
            decoded = cast(object, json5.loads(raw_jsonc))
        except Exception as error:  # noqa: BLE001
            return GraphqlMetadataParseResult(
                metadata=None,
                diagnostics=(
                    GraphqlMetadataDiagnostic(
                        severity=GraphqlMetadataSeverity.ERROR,
                        code="metadata_invalid_shape",
                        message=f"Failed to parse graphql.metadata.jsonc: {error}",
                    ),
                ),
            )

        if not isinstance(decoded, dict):
            return GraphqlMetadataParseResult(
                metadata=None,
                diagnostics=(
                    GraphqlMetadataDiagnostic(
                        severity=GraphqlMetadataSeverity.ERROR,
                        code="metadata_invalid_shape",
                        message="Top-level metadata value must be an object.",
                    ),
                ),
            )

        # The `isinstance` above establishes the shape; the cast carries it. Values stay `Any`
        # because a metadata document's values genuinely are arbitrary JSON — the helpers below each
        # check what they read.
        root = cast("dict[str, Any]", decoded)
        _collect_unknown_keys(
            map_=root,
            allowed_keys={"$schema", "version", "defaults", "objects"},
            diagnostics=diagnostics,
        )

        version = root.get("version")
        if not isinstance(version, int) or version != 1:
            diagnostics.append(
                GraphqlMetadataDiagnostic(
                    severity=GraphqlMetadataSeverity.ERROR,
                    code="metadata_invalid_shape",
                    message="Metadata version must be the integer 1.",
                    field="version",
                )
            )

        objects_value = root.get("objects")
        if not isinstance(objects_value, dict):
            diagnostics.append(
                GraphqlMetadataDiagnostic(
                    severity=GraphqlMetadataSeverity.ERROR,
                    code="metadata_invalid_shape",
                    message="Metadata objects must be an object keyed by schema.object.",
                    field="objects",
                )
            )
            return GraphqlMetadataParseResult(
                metadata=None,
                diagnostics=_sort_diagnostics(diagnostics),
            )

        # Bound once. The previous form called `_read_optional_child_map` twice — once to test for
        # None and once to read through it — so the test guarded a *different* call than the one it
        # protected, and no type checker could see the two as related.
        defaults_map = _read_optional_child_map(root, "defaults")
        defaults_limit = _parse_limit(
            scope_name="defaults.limit",
            value=defaults_map.get("limit") if defaults_map is not None else None,
            diagnostics=diagnostics,
        )

        objects: dict[str, GraphqlObjectMetadata] = {}
        # Narrowed by the `isinstance` above; the cast carries it into the loop.
        objects_map = cast("dict[str, Any]", objects_value)
        for object_id in sorted(objects_map):
            object_value = objects_map.get(object_id)
            if not isinstance(object_value, dict):
                diagnostics.append(
                    GraphqlMetadataDiagnostic(
                        severity=GraphqlMetadataSeverity.ERROR,
                        code="metadata_invalid_shape",
                        message="Metadata object entry must be an object.",
                        object_id=object_id,
                    )
                )
                continue

            object_map = cast("dict[str, Any]", object_value)
            _collect_unknown_keys(
                map_=object_map,
                allowed_keys={"publish", "name", "key", "fields", "relations", "limit"},
                diagnostics=diagnostics,
                object_id=object_id,
            )

            if object_map.get("publish") is not True:
                diagnostics.append(
                    GraphqlMetadataDiagnostic(
                        severity=GraphqlMetadataSeverity.ERROR,
                        code="metadata_invalid_shape",
                        message="Object metadata entry must declare publish: true.",
                        object_id=object_id,
                        field="publish",
                    )
                )
                continue

            metadata = GraphqlObjectMetadata(
                publish=True,
                name=_read_optional_string(object_map, "name", diagnostics, object_id),
                key=_read_optional_string_list(object_map, "key", diagnostics, object_id),
                fields=_parse_fields(object_map.get("fields"), diagnostics, object_id),
                relations=_parse_relations(object_map.get("relations"), diagnostics, object_id),
                limit=_parse_limit(
                    scope_name=f"{object_id}.limit",
                    value=object_map.get("limit"),
                    diagnostics=diagnostics,
                    object_id=object_id,
                ),
            )
            objects[object_id] = metadata

            physical_object = physical_objects_by_id.get(object_id)
            if physical_object is None:
                diagnostics.append(
                    GraphqlMetadataDiagnostic(
                        severity=GraphqlMetadataSeverity.ERROR,
                        code="metadata_object_unknown",
                        message="Metadata references an object not present in the physical model.",
                        object_id=object_id,
                    )
                )
                continue

            if physical_object.kind is PhysicalObjectKind.VIEW and not metadata.key:
                diagnostics.append(
                    GraphqlMetadataDiagnostic(
                        severity=GraphqlMetadataSeverity.ERROR,
                        code="view_missing_identity",
                        message="Published view requires explicit key metadata in v1.",
                        object_id=object_id,
                    )
                )

        return GraphqlMetadataParseResult(
            metadata=GraphqlMetadataFile(
                version=version if isinstance(version, int) else 0,
                schema=root.get("$schema") if isinstance(root.get("$schema"), str) else None,
                defaults_limit=defaults_limit,
                objects=objects,
            ),
            diagnostics=_sort_diagnostics(diagnostics),
        )


def _collect_unknown_keys(
    *,
    map_: dict[str, Any],
    allowed_keys: set[str],
    diagnostics: list[GraphqlMetadataDiagnostic],
    object_id: str | None = None,
) -> None:
    for key in sorted(key for key in map_ if key not in allowed_keys):
        diagnostics.append(
            GraphqlMetadataDiagnostic(
                severity=GraphqlMetadataSeverity.WARNING,
                code="metadata_unknown_key",
                message=f"Unknown metadata key: {key}",
                object_id=object_id,
                field=key,
            )
        )


def _read_optional_child_map(parent: dict[str, Any], key: str) -> dict[str, Any] | None:
    value = parent.get(key)
    # `dict(x)` on an untyped mapping produces another untyped mapping. The `isinstance` establishes
    # the shape; the cast is what carries it to the caller.
    return cast("dict[str, Any]", value) if isinstance(value, dict) else None


def _read_optional_string(
    map_: dict[str, Any],
    key: str,
    diagnostics: list[GraphqlMetadataDiagnostic],
    object_id: str | None,
) -> str | None:
    value = map_.get(key)
    if value is None:
        return None
    if isinstance(value, str):
        return value
    diagnostics.append(
        GraphqlMetadataDiagnostic(
            severity=GraphqlMetadataSeverity.ERROR,
            code="metadata_invalid_shape",
            message="Metadata field must be a string.",
            object_id=object_id,
            field=key,
        )
    )
    return None


def _read_optional_string_list(
    map_: dict[str, Any],
    key: str,
    diagnostics: list[GraphqlMetadataDiagnostic],
    object_id: str | None,
) -> tuple[str, ...] | None:
    value = map_.get(key)
    if value is None:
        return None
    if not isinstance(value, list) or any(
        not isinstance(item, str) for item in cast("list[object]", value)
    ):
        diagnostics.append(
            GraphqlMetadataDiagnostic(
                severity=GraphqlMetadataSeverity.ERROR,
                code="metadata_invalid_shape",
                message="Metadata field must be an array of strings.",
                object_id=object_id,
                field=key,
            )
        )
        return None
    return tuple(cast("list[str]", value))


def _parse_fields(
    value: Any,
    diagnostics: list[GraphqlMetadataDiagnostic],
    object_id: str,
) -> dict[str, GraphqlFieldMetadata]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        diagnostics.append(
            GraphqlMetadataDiagnostic(
                severity=GraphqlMetadataSeverity.ERROR,
                code="metadata_invalid_shape",
                message="fields must be an object keyed by column name.",
                object_id=object_id,
                field="fields",
            )
        )
        return {}

    fields: dict[str, GraphqlFieldMetadata] = {}
    fields_map = cast("dict[str, Any]", value)
    for field_name in sorted(fields_map):
        field_value = fields_map.get(field_name)
        if not isinstance(field_value, dict):
            diagnostics.append(
                GraphqlMetadataDiagnostic(
                    severity=GraphqlMetadataSeverity.ERROR,
                    code="metadata_invalid_shape",
                    message="Field metadata entry must be an object.",
                    object_id=object_id,
                    field=field_name,
                )
            )
            continue

        field_map = cast("dict[str, Any]", field_value)
        _collect_unknown_keys(
            map_=dict(field_map),
            allowed_keys={"hidden", "sensitive", "noFilter", "noSort", "name"},
            diagnostics=diagnostics,
            object_id=object_id,
        )
        fields[field_name] = GraphqlFieldMetadata(
            hidden=_read_optional_bool(field_map, "hidden", diagnostics, object_id, field_name),
            sensitive=_read_optional_bool(field_map, "sensitive", diagnostics, object_id, field_name),
            no_filter=_read_optional_bool(field_map, "noFilter", diagnostics, object_id, field_name),
            no_sort=_read_optional_bool(field_map, "noSort", diagnostics, object_id, field_name),
            name=_read_optional_string(field_map, "name", diagnostics, object_id),
        )

    return fields


def _parse_relations(
    value: Any,
    diagnostics: list[GraphqlMetadataDiagnostic],
    object_id: str,
) -> tuple[GraphqlRelationMetadata, ...]:
    if value is None:
        return ()
    if not isinstance(value, list):
        diagnostics.append(
            GraphqlMetadataDiagnostic(
                severity=GraphqlMetadataSeverity.ERROR,
                code="metadata_invalid_shape",
                message="relations must be an array.",
                object_id=object_id,
                field="relations",
            )
        )
        return ()

    relations: list[GraphqlRelationMetadata] = []
    for entry in cast("list[object]", value):
        if not isinstance(entry, dict):
            diagnostics.append(
                GraphqlMetadataDiagnostic(
                    severity=GraphqlMetadataSeverity.ERROR,
                    code="metadata_invalid_shape",
                    message="Relation entry must be an object.",
                    object_id=object_id,
                    field="relations",
                )
            )
            continue

        entry_map = cast("dict[str, Any]", entry)
        _collect_unknown_keys(
            map_=dict(entry_map),
            allowed_keys={"name", "cardinality", "target", "via"},
            diagnostics=diagnostics,
            object_id=object_id,
        )
        # `via` is only read when it really is an array. The previous form put that check inside the
        # comprehension's `if`, so it tested the container once per item and dropped every item when the
        # test failed — the same result, reached by filtering items on a property of their container.
        via_value = entry_map.get("via")
        relations.append(
            GraphqlRelationMetadata(
                name=str(entry_map.get("name", "")),
                cardinality=str(entry_map.get("cardinality", "")),
                target=str(entry_map.get("target", "")),
                via=(
                    tuple(str(item) for item in cast("list[Any]", via_value))
                    if isinstance(via_value, list)
                    else ()
                ),
            )
        )

    return tuple(relations)


def _parse_limit(
    *,
    scope_name: str,
    value: Any,
    diagnostics: list[GraphqlMetadataDiagnostic],
    object_id: str | None = None,
) -> GraphqlMetadataLimit | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        diagnostics.append(
            GraphqlMetadataDiagnostic(
                severity=GraphqlMetadataSeverity.ERROR,
                code="metadata_invalid_shape",
                message="Limit metadata must be an object.",
                object_id=object_id,
                field=scope_name,
            )
        )
        return None

    limit_map = cast("dict[str, Any]", value)
    default_value = limit_map.get("default")
    max_value = limit_map.get("max")
    if not isinstance(default_value, int) or not isinstance(max_value, int):
        diagnostics.append(
            GraphqlMetadataDiagnostic(
                severity=GraphqlMetadataSeverity.ERROR,
                code="metadata_invalid_shape",
                message="Limit metadata requires integer default and max values.",
                object_id=object_id,
                field=scope_name,
            )
        )
        return None
    if default_value > max_value:
        diagnostics.append(
            GraphqlMetadataDiagnostic(
                severity=GraphqlMetadataSeverity.ERROR,
                code="metadata_invalid_shape",
                message="Limit metadata requires default <= max.",
                object_id=object_id,
                field=scope_name,
            )
        )

    return GraphqlMetadataLimit(default_value=default_value, max_value=max_value)


def _read_optional_bool(
    map_: dict[str, Any],
    key: str,
    diagnostics: list[GraphqlMetadataDiagnostic],
    object_id: str | None,
    field: str,
) -> bool:
    value = map_.get(key)
    if value is None:
        return False
    if isinstance(value, bool):
        return value
    diagnostics.append(
        GraphqlMetadataDiagnostic(
            severity=GraphqlMetadataSeverity.ERROR,
            code="metadata_invalid_shape",
            message="Metadata flag must be a boolean.",
            object_id=object_id,
            field=field,
        )
    )
    return False


def _sort_diagnostics(
    diagnostics: list[GraphqlMetadataDiagnostic],
) -> tuple[GraphqlMetadataDiagnostic, ...]:
    severity_rank = {
        GraphqlMetadataSeverity.ERROR: 0,
        GraphqlMetadataSeverity.WARNING: 1,
    }
    return tuple(
        sorted(
            diagnostics,
            key=lambda diagnostic: (
                severity_rank[diagnostic.severity],
                diagnostic.code,
                diagnostic.object_id or "",
                diagnostic.field or "",
                diagnostic.message,
            ),
        )
    )