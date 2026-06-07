"""GraphQL catalog builder for Stage 3 governed naming and source digest."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
import hashlib
import json
import re
from typing import Any

from modular_api.graphql.metadata import (
    GraphqlFieldMetadata,
    GraphqlMetadataDiagnostic,
    GraphqlMetadataFile,
    GraphqlMetadataLimit,
    GraphqlObjectMetadata,
    GraphqlRelationMetadata,
)
from modular_api.graphql.sqlserver.physical_model import (
    PhysicalCatalog,
    PhysicalField,
    PhysicalObject,
    PhysicalObjectKind,
)


class GraphqlCatalogBuildMode(str, Enum):
    COMPILE = "compile"
    RUNTIME = "runtime"


class GraphqlCatalogDiagnosticSeverity(str, Enum):
    ERROR = "error"
    WARNING = "warning"
    INFO = "info"


class GraphqlCatalogOrigin(str, Enum):
    INFERRED = "inferred"
    ANNOTATED = "annotated"


class GraphqlCatalogIdentityMode(str, Enum):
    SINGLE = "single"
    COMPOSITE = "composite"
    NONE = "none"


class GraphqlCatalogFieldVisibility(str, Enum):
    PUBLIC = "public"
    HIDDEN = "hidden"


class GraphqlCatalogRelationCardinality(str, Enum):
    ONE = "one"
    MANY = "many"


class GraphqlCatalogPaginationMode(str, Enum):
    OFFSET = "offset"
    NONE = "none"


@dataclass(frozen=True, slots=True)
class GraphqlCatalogDiagnostic:
    severity: GraphqlCatalogDiagnosticSeverity
    code: str
    message: str
    object_id: str | None = None
    field: str | None = None


@dataclass(frozen=True, slots=True)
class GraphqlCatalogProvider:
    kind: str
    engine: str
    provider_version: str


@dataclass(frozen=True, slots=True)
class GraphqlCatalogBuild:
    mode: GraphqlCatalogBuildMode
    source_root: str
    source_digest: str


@dataclass(frozen=True, slots=True)
class GraphqlCatalogGraphqlNames:
    type_name: str
    collection_field: str
    item_field: str | None


@dataclass(frozen=True, slots=True)
class GraphqlCatalogSource:
    schema_name: str
    object_name: str
    source_file: str | None = None
    provider_object_id: str | None = None


@dataclass(frozen=True, slots=True)
class GraphqlCatalogIdentity:
    mode: GraphqlCatalogIdentityMode
    fields: tuple[str, ...]
    origin: GraphqlCatalogOrigin


@dataclass(frozen=True, slots=True)
class GraphqlCatalogField:
    column: str
    public_name: str
    type: str
    nullable: bool
    visibility: GraphqlCatalogFieldVisibility
    filterable: bool
    sortable: bool
    sensitive: bool
    origin: GraphqlCatalogOrigin


@dataclass(frozen=True, slots=True)
class GraphqlCatalogRelation:
    name: str
    target: str
    cardinality: GraphqlCatalogRelationCardinality
    source_fields: tuple[str, ...]
    target_fields: tuple[str, ...]
    origin: GraphqlCatalogOrigin


@dataclass(frozen=True, slots=True)
class GraphqlCatalogPagination:
    mode: GraphqlCatalogPaginationMode
    default_limit: int
    max_limit: int


@dataclass(frozen=True, slots=True)
class GraphqlCatalogCapabilities:
    item: bool
    collection: bool
    filter: bool
    sort: bool
    pagination: GraphqlCatalogPagination


@dataclass(frozen=True, slots=True)
class GraphqlPublishedObject:
    id: str
    kind: PhysicalObjectKind
    readonly: bool
    source: GraphqlCatalogSource
    graphql: GraphqlCatalogGraphqlNames
    identity: GraphqlCatalogIdentity
    fields: tuple[GraphqlCatalogField, ...]
    relations: tuple[GraphqlCatalogRelation, ...]
    capabilities: GraphqlCatalogCapabilities


@dataclass(frozen=True, slots=True)
class GraphqlCatalog:
    catalog_version: str
    provider: GraphqlCatalogProvider
    build: GraphqlCatalogBuild
    objects: tuple[GraphqlPublishedObject, ...]
    diagnostics: tuple[GraphqlCatalogDiagnostic, ...]


@dataclass(frozen=True, slots=True)
class _CatalogObjectContext:
    physical_object: PhysicalObject
    object_metadata: GraphqlObjectMetadata
    type_name: str
    item_field: str | None
    collection_field: str
    identity: GraphqlCatalogIdentity


class GraphqlCatalogNaming:
    _segment_pattern = re.compile(r"[A-Za-z0-9]+")
    _word_pattern = re.compile(r"[A-Z]+(?:\d+)?(?=[A-Z][a-z]|$)|[A-Z]?[a-z]+\d*|\d+")

    @staticmethod
    def type_name_for_object_name(value: str) -> str:
        tokens = GraphqlCatalogNaming._tokenize(value)
        if not tokens:
            return ""
        return "".join(GraphqlCatalogNaming._pascal_token(token) for token in tokens)

    @staticmethod
    def public_field_name_for_column(value: str) -> str:
        tokens = GraphqlCatalogNaming._tokenize(value)
        if not tokens:
            return ""

        head = GraphqlCatalogNaming._pascal_token(tokens[0])
        tail = "".join(GraphqlCatalogNaming._pascal_token(token) for token in tokens[1:])
        return GraphqlCatalogNaming._camel_token(head) + tail

    @staticmethod
    def _tokenize(value: str) -> list[str]:
        trimmed = value.strip()
        if not trimmed:
            return []

        tokens: list[str] = []
        for segment in GraphqlCatalogNaming._segment_pattern.findall(trimmed):
            tokens.extend(token for token in GraphqlCatalogNaming._word_pattern.findall(segment) if token)
        return tokens

    @staticmethod
    def _pascal_token(token: str) -> str:
        if not token or token.isdigit():
            return token
        lower = token.lower()
        return f"{lower[0].upper()}{lower[1:]}"

    @staticmethod
    def _camel_token(token: str) -> str:
        if not token:
            return token
        return f"{token[0].lower()}{token[1:]}"


class GraphqlCatalogBuilder:
    def __init__(
        self,
        *,
        provider_version: str,
        source_root: str,
        build_mode: GraphqlCatalogBuildMode,
        engine: str,
    ) -> None:
        self._provider_version = provider_version
        self._source_root = source_root
        self._build_mode = build_mode
        self._engine = engine

    def build(
        self,
        *,
        physical_catalog: PhysicalCatalog,
        metadata: GraphqlMetadataFile,
    ) -> GraphqlCatalog:
        diagnostics: list[GraphqlCatalogDiagnostic] = []
        physical_objects_by_id = {object_.id: object_ for object_ in physical_catalog.objects}
        contexts: dict[str, _CatalogObjectContext] = {}

        for object_id in sorted(metadata.objects.keys()):
            physical_object = physical_objects_by_id.get(object_id)
            if physical_object is None:
                diagnostics.append(
                    GraphqlCatalogDiagnostic(
                        severity=GraphqlCatalogDiagnosticSeverity.ERROR,
                        code="metadata_object_unknown",
                        message="Metadata references an object not present in the physical model.",
                        object_id=object_id,
                    )
                )
                continue

            object_metadata = metadata.objects[object_id]
            identity = self._resolve_identity(
                physical_object=physical_object,
                object_metadata=object_metadata,
                diagnostics=diagnostics,
            )
            type_name = object_metadata.name or GraphqlCatalogNaming.type_name_for_object_name(
                physical_object.object_name
            )
            item_field = (
                None
                if identity.mode is GraphqlCatalogIdentityMode.NONE
                else GraphqlCatalogNaming.public_field_name_for_column(type_name)
            )
            collection_field = f"{GraphqlCatalogNaming.public_field_name_for_column(type_name)}List"
            contexts[object_id] = _CatalogObjectContext(
                physical_object=physical_object,
                object_metadata=object_metadata,
                type_name=type_name,
                item_field=item_field,
                collection_field=collection_field,
                identity=identity,
            )

        objects = tuple(
            sorted(
                (
                    self._build_object(
                        context=contexts[object_id],
                        all_contexts=contexts,
                        defaults_limit=metadata.defaults_limit,
                        diagnostics=diagnostics,
                    )
                    for object_id in contexts
                ),
                key=lambda object_: object_.id,
            )
        )

        self._detect_duplicate_object_names(objects, diagnostics)
        sorted_diagnostics = self._sort_diagnostics(diagnostics)

        catalog_without_digest = GraphqlCatalog(
            catalog_version="1.0.0",
            provider=GraphqlCatalogProvider(
                kind="sql",
                engine=self._engine,
                provider_version=self._provider_version,
            ),
            build=GraphqlCatalogBuild(
                mode=self._build_mode,
                source_root=self._source_root,
                source_digest="",
            ),
            objects=objects,
            diagnostics=sorted_diagnostics,
        )

        return GraphqlCatalog(
            catalog_version=catalog_without_digest.catalog_version,
            provider=catalog_without_digest.provider,
            build=GraphqlCatalogBuild(
                mode=catalog_without_digest.build.mode,
                source_root=catalog_without_digest.build.source_root,
                source_digest=self._compute_source_digest(catalog_without_digest),
            ),
            objects=catalog_without_digest.objects,
            diagnostics=catalog_without_digest.diagnostics,
        )

    def _resolve_identity(
        self,
        *,
        physical_object: PhysicalObject,
        object_metadata: GraphqlObjectMetadata,
        diagnostics: list[GraphqlCatalogDiagnostic],
    ) -> GraphqlCatalogIdentity:
        if object_metadata.key:
            return GraphqlCatalogIdentity(
                mode=(
                    GraphqlCatalogIdentityMode.SINGLE
                    if len(object_metadata.key) == 1
                    else GraphqlCatalogIdentityMode.COMPOSITE
                ),
                fields=tuple(object_metadata.key),
                origin=GraphqlCatalogOrigin.ANNOTATED,
            )

        if physical_object.identity_fields:
            return GraphqlCatalogIdentity(
                mode=(
                    GraphqlCatalogIdentityMode.SINGLE
                    if len(physical_object.identity_fields) == 1
                    else GraphqlCatalogIdentityMode.COMPOSITE
                ),
                fields=tuple(physical_object.identity_fields),
                origin=GraphqlCatalogOrigin.INFERRED,
            )

        if physical_object.kind is PhysicalObjectKind.VIEW:
            diagnostics.append(
                GraphqlCatalogDiagnostic(
                    severity=GraphqlCatalogDiagnosticSeverity.ERROR,
                    code="view_missing_identity",
                    message="Published view requires explicit identity metadata.",
                    object_id=physical_object.id,
                )
            )

        return GraphqlCatalogIdentity(
            mode=GraphqlCatalogIdentityMode.NONE,
            fields=(),
            origin=GraphqlCatalogOrigin.INFERRED,
        )

    def _build_object(
        self,
        *,
        context: _CatalogObjectContext,
        all_contexts: dict[str, _CatalogObjectContext],
        defaults_limit: GraphqlMetadataLimit | None,
        diagnostics: list[GraphqlCatalogDiagnostic],
    ) -> GraphqlPublishedObject:
        fields = tuple(
            sorted(
                (
                    self._build_field(
                        object_id=context.physical_object.id,
                        physical_field=field,
                        field_metadata=context.object_metadata.fields.get(field.column)
                        if context.object_metadata.fields is not None
                        else None,
                        diagnostics=diagnostics,
                    )
                    for field in context.physical_object.fields
                ),
                key=lambda field: (field.public_name, field.column),
            )
        )
        self._detect_duplicate_field_names(context.physical_object.id, fields, diagnostics)
        relations = self._build_relations(
            context=context,
            all_contexts=all_contexts,
            diagnostics=diagnostics,
        )
        pagination = self._resolve_pagination(context.object_metadata.limit, defaults_limit)

        return GraphqlPublishedObject(
            id=context.physical_object.id,
            kind=context.physical_object.kind,
            readonly=True,
            source=GraphqlCatalogSource(
                schema_name=context.physical_object.schema_name,
                object_name=context.physical_object.object_name,
            ),
            graphql=GraphqlCatalogGraphqlNames(
                type_name=context.type_name,
                collection_field=context.collection_field,
                item_field=context.item_field,
            ),
            identity=context.identity,
            fields=fields,
            relations=relations,
            capabilities=GraphqlCatalogCapabilities(
                item=context.identity.mode is not GraphqlCatalogIdentityMode.NONE,
                collection=True,
                filter=any(
                    field.visibility is GraphqlCatalogFieldVisibility.PUBLIC and field.filterable
                    for field in fields
                ),
                sort=any(
                    field.visibility is GraphqlCatalogFieldVisibility.PUBLIC and field.sortable
                    for field in fields
                ),
                pagination=pagination,
            ),
        )

    def _build_field(
        self,
        *,
        object_id: str,
        physical_field: PhysicalField,
        field_metadata: GraphqlFieldMetadata | None,
        diagnostics: list[GraphqlCatalogDiagnostic],
    ) -> GraphqlCatalogField:
        type_name = self._normalize_scalar(
            object_id=object_id,
            column=physical_field.column,
            native_type=physical_field.native_type,
            diagnostics=diagnostics,
        )
        public_name = (
            field_metadata.name
            if field_metadata is not None and field_metadata.name is not None
            else GraphqlCatalogNaming.public_field_name_for_column(physical_field.column)
        )
        visibility = (
            GraphqlCatalogFieldVisibility.HIDDEN
            if field_metadata is not None and field_metadata.hidden
            else GraphqlCatalogFieldVisibility.PUBLIC
        )
        filterable = (
            visibility is GraphqlCatalogFieldVisibility.PUBLIC
            and not (field_metadata is not None and field_metadata.no_filter)
            and type_name != "Json"
        )
        sortable = (
            visibility is GraphqlCatalogFieldVisibility.PUBLIC
            and not (field_metadata is not None and field_metadata.no_sort)
            and type_name != "Json"
        )

        return GraphqlCatalogField(
            column=physical_field.column,
            public_name=public_name,
            type=type_name,
            nullable=physical_field.nullable,
            visibility=visibility,
            filterable=filterable,
            sortable=sortable,
            sensitive=field_metadata.sensitive if field_metadata is not None else False,
            origin=(
                GraphqlCatalogOrigin.ANNOTATED
                if field_metadata is not None
                else GraphqlCatalogOrigin.INFERRED
            ),
        )

    def _build_relations(
        self,
        *,
        context: _CatalogObjectContext,
        all_contexts: dict[str, _CatalogObjectContext],
        diagnostics: list[GraphqlCatalogDiagnostic],
    ) -> tuple[GraphqlCatalogRelation, ...]:
        relations: list[GraphqlCatalogRelation] = []
        if context.physical_object.kind is PhysicalObjectKind.TABLE:
            for relation_seed in context.physical_object.relations:
                target_context = all_contexts.get(relation_seed.target_object_id)
                if target_context is None:
                    diagnostics.append(
                        GraphqlCatalogDiagnostic(
                            severity=GraphqlCatalogDiagnosticSeverity.ERROR,
                            code="relation_target_unknown",
                            message="Relation target is not published in the governed catalog.",
                            object_id=context.physical_object.id,
                            field=relation_seed.name,
                        )
                    )
                    continue
                relations.append(
                    GraphqlCatalogRelation(
                        name=GraphqlCatalogNaming.public_field_name_for_column(relation_seed.name),
                        target=relation_seed.target_object_id,
                        cardinality=GraphqlCatalogRelationCardinality.ONE,
                        source_fields=relation_seed.source_fields,
                        target_fields=relation_seed.target_fields,
                        origin=GraphqlCatalogOrigin.INFERRED,
                    )
                )
        else:
            for relation_metadata in context.object_metadata.relations:
                target_context = all_contexts.get(relation_metadata.target)
                if target_context is None or target_context.identity.mode is GraphqlCatalogIdentityMode.NONE:
                    diagnostics.append(
                        GraphqlCatalogDiagnostic(
                            severity=GraphqlCatalogDiagnosticSeverity.ERROR,
                            code="relation_target_unknown",
                            message="Relation target is not published with usable identity.",
                            object_id=context.physical_object.id,
                            field=relation_metadata.name,
                        )
                    )
                    continue
                relations.append(
                    GraphqlCatalogRelation(
                        name=relation_metadata.name,
                        target=relation_metadata.target,
                        cardinality=(
                            GraphqlCatalogRelationCardinality.MANY
                            if relation_metadata.cardinality == "to-many"
                            else GraphqlCatalogRelationCardinality.ONE
                        ),
                        source_fields=tuple(relation_metadata.via),
                        target_fields=tuple(target_context.identity.fields),
                        origin=GraphqlCatalogOrigin.ANNOTATED,
                    )
                )

        return tuple(sorted(relations, key=lambda relation: (relation.name, relation.target)))

    def _resolve_pagination(
        self,
        object_limit: GraphqlMetadataLimit | None,
        defaults_limit: GraphqlMetadataLimit | None,
    ) -> GraphqlCatalogPagination:
        effective_limit = object_limit or defaults_limit or GraphqlMetadataLimit(default_value=50, max_value=200)
        return GraphqlCatalogPagination(
            mode=GraphqlCatalogPaginationMode.OFFSET,
            default_limit=effective_limit.default_value,
            max_limit=effective_limit.max_value,
        )

    def _normalize_scalar(
        self,
        *,
        object_id: str,
        column: str,
        native_type: str,
        diagnostics: list[GraphqlCatalogDiagnostic],
    ) -> str:
        normalized = native_type.strip().lower()
        if normalized.startswith("bigint"):
            return "Long"
        if normalized.startswith("int") or normalized.startswith("smallint") or normalized.startswith("tinyint"):
            return "Int"
        if (
            normalized.startswith("decimal")
            or normalized.startswith("numeric")
            or normalized.startswith("money")
            or normalized.startswith("smallmoney")
        ):
            return "Decimal"
        if normalized.startswith("float") or normalized.startswith("real"):
            return "Float"
        if normalized.startswith("bit"):
            return "Boolean"
        if normalized.startswith("date") and not normalized.startswith("datetime"):
            return "Date"
        if (
            normalized.startswith("datetime")
            or normalized.startswith("smalldatetime")
            or normalized.startswith("datetimeoffset")
        ):
            return "DateTime"
        if normalized.startswith("uniqueidentifier"):
            return "Uuid"
        if normalized.startswith("json"):
            return "Json"
        if (
            normalized.startswith("char")
            or normalized.startswith("nchar")
            or normalized.startswith("varchar")
            or normalized.startswith("nvarchar")
            or normalized.startswith("text")
            or normalized.startswith("ntext")
            or normalized.startswith("xml")
        ):
            return "String"

        diagnostics.append(
            GraphqlCatalogDiagnostic(
                severity=GraphqlCatalogDiagnosticSeverity.WARNING,
                code="unsupported_scalar",
                message=f"Native type {native_type} is not mapped explicitly in the v1 scalar domain.",
                object_id=object_id,
                field=column,
            )
        )
        return "String"

    def _detect_duplicate_field_names(
        self,
        object_id: str,
        fields: tuple[GraphqlCatalogField, ...],
        diagnostics: list[GraphqlCatalogDiagnostic],
    ) -> None:
        counts: dict[str, int] = {}
        for field in fields:
            counts[field.public_name] = counts.get(field.public_name, 0) + 1

        for public_name in sorted(name for name, count in counts.items() if count > 1):
            diagnostics.append(
                GraphqlCatalogDiagnostic(
                    severity=GraphqlCatalogDiagnosticSeverity.ERROR,
                    code="duplicate_public_name",
                    message="Multiple fields derive the same public GraphQL name.",
                    object_id=object_id,
                    field=public_name,
                )
            )

    def _detect_duplicate_object_names(
        self,
        objects: tuple[GraphqlPublishedObject, ...],
        diagnostics: list[GraphqlCatalogDiagnostic],
    ) -> None:
        type_counts: dict[str, int] = {}
        item_counts: dict[str, int] = {}
        collection_counts: dict[str, int] = {}

        for object_ in objects:
            type_counts[object_.graphql.type_name] = type_counts.get(object_.graphql.type_name, 0) + 1
            collection_counts[object_.graphql.collection_field] = (
                collection_counts.get(object_.graphql.collection_field, 0) + 1
            )
            if object_.graphql.item_field is not None:
                item_counts[object_.graphql.item_field] = item_counts.get(object_.graphql.item_field, 0) + 1

        for object_ in objects:
            if type_counts[object_.graphql.type_name] > 1:
                diagnostics.append(
                    GraphqlCatalogDiagnostic(
                        severity=GraphqlCatalogDiagnosticSeverity.ERROR,
                        code="duplicate_public_name",
                        message="Multiple objects derive the same GraphQL type name.",
                        object_id=object_.id,
                        field=object_.graphql.type_name,
                    )
                )
            if collection_counts[object_.graphql.collection_field] > 1:
                diagnostics.append(
                    GraphqlCatalogDiagnostic(
                        severity=GraphqlCatalogDiagnosticSeverity.ERROR,
                        code="duplicate_public_name",
                        message="Multiple objects derive the same collection field name.",
                        object_id=object_.id,
                        field=object_.graphql.collection_field,
                    )
                )
            if object_.graphql.item_field is not None and item_counts[object_.graphql.item_field] > 1:
                diagnostics.append(
                    GraphqlCatalogDiagnostic(
                        severity=GraphqlCatalogDiagnosticSeverity.ERROR,
                        code="duplicate_public_name",
                        message="Multiple objects derive the same item field name.",
                        object_id=object_.id,
                        field=object_.graphql.item_field,
                    )
                )

    def _sort_diagnostics(
        self,
        diagnostics: list[GraphqlCatalogDiagnostic],
    ) -> tuple[GraphqlCatalogDiagnostic, ...]:
        severity_rank = {
            GraphqlCatalogDiagnosticSeverity.ERROR: 0,
            GraphqlCatalogDiagnosticSeverity.WARNING: 1,
            GraphqlCatalogDiagnosticSeverity.INFO: 2,
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

    def _compute_source_digest(self, catalog: GraphqlCatalog) -> str:
        payload = {
            "engine": self._engine,
            "providerVersion": self._provider_version,
            "sourceRoot": self._source_root,
            "buildMode": self._build_mode.value,
            "objects": [self._object_digest_map(object_) for object_ in catalog.objects],
        }
        canonical_json = json.dumps(self._canonicalize(payload), ensure_ascii=True, sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(canonical_json.encode("utf-8")).hexdigest()

    def _object_digest_map(self, object_: GraphqlPublishedObject) -> dict[str, Any]:
        return {
            "id": object_.id,
            "kind": object_.kind.value,
            "source": {
                "schemaName": object_.source.schema_name,
                "objectName": object_.source.object_name,
                "sourceFile": object_.source.source_file,
                "providerObjectId": object_.source.provider_object_id,
            },
            "graphql": {
                "typeName": object_.graphql.type_name,
                "collectionField": object_.graphql.collection_field,
                "itemField": object_.graphql.item_field,
            },
            "identity": {
                "mode": object_.identity.mode.value,
                "fields": list(object_.identity.fields),
                "origin": object_.identity.origin.value,
            },
            "fields": [
                {
                    "column": field.column,
                    "publicName": field.public_name,
                    "type": field.type,
                    "nullable": field.nullable,
                    "visibility": field.visibility.value,
                    "filterable": field.filterable,
                    "sortable": field.sortable,
                    "sensitive": field.sensitive,
                    "origin": field.origin.value,
                }
                for field in object_.fields
            ],
            "relations": [
                {
                    "name": relation.name,
                    "target": relation.target,
                    "cardinality": relation.cardinality.value,
                    "sourceFields": list(relation.source_fields),
                    "targetFields": list(relation.target_fields),
                    "origin": relation.origin.value,
                }
                for relation in object_.relations
            ],
            "capabilities": {
                "item": object_.capabilities.item,
                "collection": object_.capabilities.collection,
                "filter": object_.capabilities.filter,
                "sort": object_.capabilities.sort,
                "pagination": {
                    "mode": object_.capabilities.pagination.mode.value,
                    "defaultLimit": object_.capabilities.pagination.default_limit,
                    "maxLimit": object_.capabilities.pagination.max_limit,
                },
            },
        }

    def _canonicalize(self, value: Any) -> Any:
        if isinstance(value, dict):
            return {key: self._canonicalize(value[key]) for key in sorted(value)}
        if isinstance(value, (list, tuple)):
            return [self._canonicalize(entry) for entry in value]
        return value