"""GraphQL artifact compiler and runtime artifact loading for Stage 8."""

from __future__ import annotations

import asyncio
import inspect
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from modular_api.graphql.catalog import (
    GraphqlCatalog,
    GraphqlCatalogBuild,
    GraphqlCatalogBuildMode,
    GraphqlCatalogCapabilities,
    GraphqlCatalogDiagnostic,
    GraphqlCatalogDiagnosticSeverity,
    GraphqlCatalogField,
    GraphqlCatalogFieldVisibility,
    GraphqlCatalogGraphqlNames,
    GraphqlCatalogIdentity,
    GraphqlCatalogIdentityMode,
    GraphqlCatalogOrigin,
    GraphqlCatalogPagination,
    GraphqlCatalogPaginationMode,
    GraphqlCatalogProvider,
    GraphqlCatalogRelation,
    GraphqlCatalogRelationCardinality,
    GraphqlCatalogSource,
    GraphqlPublishedObject,
)
from modular_api.graphql.runtime.graphql_runtime_options import GraphqlOptions
from modular_api.graphql.schema import GraphqlSchemaSdlGenerator
from modular_api.graphql.sqlserver import PhysicalObjectKind

_CATALOG_FILE_NAME = "catalog.json"
_CATALOG_LOCK_FILE_NAME = "catalog.lock"
_DIAGNOSTICS_FILE_NAME = "diagnostics.json"
_SCHEMA_FILE_NAME = "schema.graphql"

_DIAGNOSTIC_SEVERITY_ORDER = {
    GraphqlCatalogDiagnosticSeverity.ERROR: 0,
    GraphqlCatalogDiagnosticSeverity.WARNING: 1,
    GraphqlCatalogDiagnosticSeverity.INFO: 2,
}


@dataclass(frozen=True, slots=True)
class GraphqlArtifactBundle:
    catalog_json: str
    catalog_lock_json: str
    diagnostics_json: str
    schema_graphql: str

    def write_to_directory(self, output_directory: str) -> None:
        directory = Path(output_directory)
        directory.mkdir(parents=True, exist_ok=True)
        (directory / _CATALOG_FILE_NAME).write_text(self.catalog_json, encoding="utf-8")
        (directory / _CATALOG_LOCK_FILE_NAME).write_text(self.catalog_lock_json, encoding="utf-8")
        (directory / _DIAGNOSTICS_FILE_NAME).write_text(self.diagnostics_json, encoding="utf-8")
        (directory / _SCHEMA_FILE_NAME).write_text(self.schema_graphql, encoding="utf-8")


class GraphqlArtifactCompileError(Exception):
    def __init__(self, *, message: str, bundle: GraphqlArtifactBundle) -> None:
        super().__init__(message)
        self.bundle = bundle


class GraphqlArtifactLoadError(Exception):
    pass


class GraphqlArtifactCompiler:
    def __init__(
        self,
        *,
        catalog_factory: Callable[[], Any],
        sdl_factory: Callable[[GraphqlCatalog], str] | None = None,
    ) -> None:
        self._catalog_factory = catalog_factory
        self._sdl_factory = sdl_factory or GraphqlSchemaSdlGenerator().generate

    def compile(self) -> GraphqlArtifactBundle:
        raw_catalog = _resolve_maybe_awaitable(self._catalog_factory())
        catalog = _canonical_catalog(raw_catalog)
        bundle = GraphqlArtifactBundle(
            catalog_json=_pretty_json(_catalog_to_json(catalog)),
            catalog_lock_json=_pretty_json(_catalog_lock_to_json(catalog)),
            diagnostics_json=_pretty_json(_diagnostics_to_json(catalog.diagnostics)),
            schema_graphql=_normalized_schema(self._sdl_factory(catalog)),
        )

        blocking_diagnostics = [
            diagnostic
            for diagnostic in catalog.diagnostics
            if diagnostic.severity is GraphqlCatalogDiagnosticSeverity.ERROR
        ]
        if blocking_diagnostics:
            raise GraphqlArtifactCompileError(
                message="GraphQL artifact compilation failed because blocking diagnostics exist.",
                bundle=bundle,
            )

        return bundle

    def write_to_directory(self, output_directory: str) -> GraphqlArtifactBundle:
        try:
            bundle = self.compile()
            bundle.write_to_directory(output_directory)
            return bundle
        except GraphqlArtifactCompileError as error:
            error.bundle.write_to_directory(output_directory)
            raise


def try_load_graphql_catalog_artifacts(
    *,
    artifact_directory: str,
    current_source_digest: str,
) -> GraphqlCatalog | None:
    directory = Path(artifact_directory)
    catalog_path = directory / _CATALOG_FILE_NAME
    lock_path = directory / _CATALOG_LOCK_FILE_NAME
    if not catalog_path.is_file() or not lock_path.is_file():
        return None

    lock = _catalog_lock_from_json(
        _parse_json_object(lock_path.read_text(encoding="utf-8"), "catalog.lock must be a JSON object.")
    )
    if lock["sourceDigest"] != current_source_digest:
        return None

    catalog = _canonical_catalog(
        _catalog_from_json(
            _parse_json_object(catalog_path.read_text(encoding="utf-8"), "catalog.json must be a JSON object.")
        )
    )
    if (
        catalog.catalog_version != lock["catalogVersion"]
        or catalog.build.source_digest != lock["sourceDigest"]
        or catalog.provider.provider_version != lock["providerVersion"]
    ):
        return None

    return catalog


def resolve_catalog_from_artifacts_or_source(options: GraphqlOptions) -> GraphqlCatalog:
    if options.artifact_directory is not None and options.source_digest_factory is not None:
        try:
            current_source_digest = _resolve_maybe_awaitable(options.source_digest_factory())
            prebuilt_catalog = try_load_graphql_catalog_artifacts(
                artifact_directory=options.artifact_directory,
                current_source_digest=current_source_digest,
            )
            if prebuilt_catalog is not None:
                return prebuilt_catalog
        except Exception as error:  # noqa: BLE001
            raise GraphqlArtifactLoadError(str(error)) from error

    return _resolve_maybe_awaitable(options.catalog_factory())


def _resolve_maybe_awaitable(value: Any) -> Any:
    if inspect.isawaitable(value):
        return asyncio.run(value)
    return value


def _pretty_json(payload: Any) -> str:
    return json.dumps(payload, indent=2, sort_keys=True) + "\n"


def _normalized_schema(schema: str) -> str:
    return schema if schema.endswith("\n") else f"{schema}\n"


def _canonical_catalog(catalog: GraphqlCatalog) -> GraphqlCatalog:
    objects = tuple(sorted((_canonical_object(object_) for object_ in catalog.objects), key=lambda object_: object_.id))
    diagnostics = tuple(sorted(catalog.diagnostics, key=_diagnostic_sort_key))
    return GraphqlCatalog(
        catalog_version=catalog.catalog_version,
        provider=catalog.provider,
        build=catalog.build,
        objects=objects,
        diagnostics=diagnostics,
    )


def _canonical_object(object_: GraphqlPublishedObject) -> GraphqlPublishedObject:
    fields = tuple(sorted(object_.fields, key=lambda field: (field.public_name, field.column)))
    relations = tuple(sorted(object_.relations, key=lambda relation: (relation.name, relation.target)))
    return GraphqlPublishedObject(
        id=object_.id,
        kind=object_.kind,
        readonly=object_.readonly,
        source=object_.source,
        graphql=object_.graphql,
        identity=object_.identity,
        fields=fields,
        relations=relations,
        capabilities=object_.capabilities,
    )


def _diagnostic_sort_key(diagnostic: GraphqlCatalogDiagnostic) -> tuple[int, str, str, str, str]:
    return (
        _DIAGNOSTIC_SEVERITY_ORDER[diagnostic.severity],
        diagnostic.code,
        diagnostic.object_id or "",
        diagnostic.field or "",
        diagnostic.message,
    )


def _catalog_to_json(catalog: GraphqlCatalog) -> dict[str, Any]:
    return {
        "catalogVersion": catalog.catalog_version,
        "provider": {
            "kind": catalog.provider.kind,
            "engine": catalog.provider.engine,
            "providerVersion": catalog.provider.provider_version,
        },
        "build": {
            "mode": catalog.build.mode.value,
            "sourceRoot": catalog.build.source_root,
            "sourceDigest": catalog.build.source_digest,
        },
        "objects": [_object_to_json(object_) for object_ in catalog.objects],
        "diagnostics": _diagnostics_to_json(catalog.diagnostics),
    }


def _catalog_lock_to_json(catalog: GraphqlCatalog) -> dict[str, Any]:
    return {
        "catalogVersion": catalog.catalog_version,
        "sourceDigest": catalog.build.source_digest,
        "providerVersion": catalog.provider.provider_version,
    }


def _diagnostics_to_json(diagnostics: tuple[GraphqlCatalogDiagnostic, ...]) -> list[dict[str, Any]]:
    return [
        {
            "severity": diagnostic.severity.value,
            "code": diagnostic.code,
            "message": diagnostic.message,
            "objectId": diagnostic.object_id,
            "field": diagnostic.field,
        }
        for diagnostic in diagnostics
    ]


def _object_to_json(object_: GraphqlPublishedObject) -> dict[str, Any]:
    return {
        "id": object_.id,
        "kind": object_.kind.value,
        "readonly": object_.readonly,
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


def _catalog_from_json(payload: dict[str, Any]) -> GraphqlCatalog:
    provider_json = _require_object(payload.get("provider"), "catalog.json provider must be an object.")
    build_json = _require_object(payload.get("build"), "catalog.json build must be an object.")
    objects_json = _require_list(payload.get("objects"), "catalog.json objects must be an array.")
    diagnostics_json = payload.get("diagnostics") or []
    if not isinstance(diagnostics_json, list):
        raise GraphqlArtifactLoadError("catalog.json diagnostics must be an array.")

    return GraphqlCatalog(
        catalog_version=_require_string(payload.get("catalogVersion"), "catalog.json catalogVersion must be a string."),
        provider=GraphqlCatalogProvider(
            kind=_require_string(provider_json.get("kind"), "catalog.json provider.kind must be a string."),
            engine=_require_string(provider_json.get("engine"), "catalog.json provider.engine must be a string."),
            provider_version=_require_string(
                provider_json.get("providerVersion"),
                "catalog.json provider.providerVersion must be a string.",
            ),
        ),
        build=GraphqlCatalogBuild(
            mode=_require_build_mode(build_json.get("mode")),
            source_root=_require_string(
                build_json.get("sourceRoot"),
                "catalog.json build.sourceRoot must be a string.",
            ),
            source_digest=_require_string(
                build_json.get("sourceDigest"),
                "catalog.json build.sourceDigest must be a string.",
            ),
        ),
        objects=tuple(_object_from_json(_require_object(object_json, "catalog.json object must be an object.")) for object_json in objects_json),
        diagnostics=tuple(
            _diagnostic_from_json(_require_object(diagnostic_json, "catalog.json diagnostic must be an object."))
            for diagnostic_json in diagnostics_json
        ),
    )


def _catalog_lock_from_json(payload: dict[str, Any]) -> dict[str, str]:
    return {
        "catalogVersion": _require_string(payload.get("catalogVersion"), "catalog.lock catalogVersion must be a string."),
        "sourceDigest": _require_string(payload.get("sourceDigest"), "catalog.lock sourceDigest must be a string."),
        "providerVersion": _require_string(payload.get("providerVersion"), "catalog.lock providerVersion must be a string."),
    }


def _object_from_json(payload: dict[str, Any]) -> GraphqlPublishedObject:
    source_json = _require_object(payload.get("source"), "catalog.json object.source must be an object.")
    graphql_json = _require_object(payload.get("graphql"), "catalog.json object.graphql must be an object.")
    identity_json = _require_object(payload.get("identity"), "catalog.json object.identity must be an object.")
    capabilities_json = _require_object(payload.get("capabilities"), "catalog.json object.capabilities must be an object.")
    pagination_json = _require_object(
        capabilities_json.get("pagination"),
        "catalog.json object.capabilities.pagination must be an object.",
    )

    return GraphqlPublishedObject(
        id=_require_string(payload.get("id"), "catalog.json object.id must be a string."),
        kind=_require_physical_object_kind(payload.get("kind")),
        readonly=_require_bool(payload.get("readonly"), "catalog.json object.readonly must be a boolean."),
        source=GraphqlCatalogSource(
            schema_name=_require_string(
                source_json.get("schemaName"),
                "catalog.json object.source.schemaName must be a string.",
            ),
            object_name=_require_string(
                source_json.get("objectName"),
                "catalog.json object.source.objectName must be a string.",
            ),
            source_file=_nullable_string(source_json.get("sourceFile")),
            provider_object_id=_nullable_string(source_json.get("providerObjectId")),
        ),
        graphql=GraphqlCatalogGraphqlNames(
            type_name=_require_string(
                graphql_json.get("typeName"),
                "catalog.json object.graphql.typeName must be a string.",
            ),
            collection_field=_require_string(
                graphql_json.get("collectionField"),
                "catalog.json object.graphql.collectionField must be a string.",
            ),
            item_field=_nullable_string(graphql_json.get("itemField")),
        ),
        identity=GraphqlCatalogIdentity(
            mode=_require_identity_mode(identity_json.get("mode")),
            fields=tuple(
                _require_string(item, "catalog.json object.identity.fields must be a string array.")
                for item in _require_list(
                    identity_json.get("fields"),
                    "catalog.json object.identity.fields must be a string array.",
                )
            ),
            origin=_require_origin(identity_json.get("origin")),
        ),
        fields=tuple(
            GraphqlCatalogField(
                column=_require_string(field_json.get("column"), "catalog.json field.column must be a string."),
                public_name=_require_string(
                    field_json.get("publicName"),
                    "catalog.json field.publicName must be a string.",
                ),
                type=_require_string(field_json.get("type"), "catalog.json field.type must be a string."),
                nullable=_require_bool(field_json.get("nullable"), "catalog.json field.nullable must be a boolean."),
                visibility=_require_field_visibility(field_json.get("visibility")),
                filterable=_require_bool(
                    field_json.get("filterable"),
                    "catalog.json field.filterable must be a boolean.",
                ),
                sortable=_require_bool(field_json.get("sortable"), "catalog.json field.sortable must be a boolean."),
                sensitive=_require_bool(field_json.get("sensitive"), "catalog.json field.sensitive must be a boolean."),
                origin=_require_origin(field_json.get("origin")),
            )
            for field_json in (
                _require_object(field_json, "catalog.json field must be an object.")
                for field_json in _require_list(payload.get("fields"), "catalog.json object.fields must be an array.")
            )
        ),
        relations=tuple(
            GraphqlCatalogRelation(
                name=_require_string(relation_json.get("name"), "catalog.json relation.name must be a string."),
                target=_require_string(relation_json.get("target"), "catalog.json relation.target must be a string."),
                cardinality=_require_relation_cardinality(relation_json.get("cardinality")),
                source_fields=tuple(
                    _require_string(item, "catalog.json relation.sourceFields must be a string array.")
                    for item in _require_list(
                        relation_json.get("sourceFields"),
                        "catalog.json relation.sourceFields must be a string array.",
                    )
                ),
                target_fields=tuple(
                    _require_string(item, "catalog.json relation.targetFields must be a string array.")
                    for item in _require_list(
                        relation_json.get("targetFields"),
                        "catalog.json relation.targetFields must be a string array.",
                    )
                ),
                origin=_require_origin(relation_json.get("origin")),
            )
            for relation_json in (
                _require_object(relation_json, "catalog.json relation must be an object.")
                for relation_json in _require_list(payload.get("relations"), "catalog.json object.relations must be an array.")
            )
        ),
        capabilities=GraphqlCatalogCapabilities(
            item=_require_bool(capabilities_json.get("item"), "catalog.json capabilities.item must be a boolean."),
            collection=_require_bool(
                capabilities_json.get("collection"),
                "catalog.json capabilities.collection must be a boolean.",
            ),
            filter=_require_bool(capabilities_json.get("filter"), "catalog.json capabilities.filter must be a boolean."),
            sort=_require_bool(capabilities_json.get("sort"), "catalog.json capabilities.sort must be a boolean."),
            pagination=GraphqlCatalogPagination(
                mode=_require_pagination_mode(pagination_json.get("mode")),
                default_limit=_require_int(
                    pagination_json.get("defaultLimit"),
                    "catalog.json pagination.defaultLimit must be an integer.",
                ),
                max_limit=_require_int(
                    pagination_json.get("maxLimit"),
                    "catalog.json pagination.maxLimit must be an integer.",
                ),
            ),
        ),
    )


def _diagnostic_from_json(payload: dict[str, Any]) -> GraphqlCatalogDiagnostic:
    return GraphqlCatalogDiagnostic(
        severity=_require_diagnostic_severity(payload.get("severity")),
        code=_require_string(payload.get("code"), "catalog.json diagnostic.code must be a string."),
        message=_require_string(payload.get("message"), "catalog.json diagnostic.message must be a string."),
        object_id=_nullable_string(payload.get("objectId")),
        field=_nullable_string(payload.get("field")),
    )


def _parse_json_object(text: str, error_message: str) -> dict[str, Any]:
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as error:
        raise GraphqlArtifactLoadError(str(error)) from error
    if not isinstance(payload, dict):
        raise GraphqlArtifactLoadError(error_message)
    return payload


def _require_object(value: Any, error_message: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise GraphqlArtifactLoadError(error_message)
    return value


def _require_list(value: Any, error_message: str) -> list[Any]:
    if not isinstance(value, list):
        raise GraphqlArtifactLoadError(error_message)
    return value


def _require_string(value: Any, error_message: str) -> str:
    if not isinstance(value, str):
        raise GraphqlArtifactLoadError(error_message)
    return value


def _nullable_string(value: Any) -> str | None:
    return value if isinstance(value, str) else None


def _require_bool(value: Any, error_message: str) -> bool:
    if not isinstance(value, bool):
        raise GraphqlArtifactLoadError(error_message)
    return value


def _require_int(value: Any, error_message: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise GraphqlArtifactLoadError(error_message)
    return value


def _require_build_mode(value: Any) -> GraphqlCatalogBuildMode:
    try:
        return GraphqlCatalogBuildMode(value)
    except ValueError as error:
        raise GraphqlArtifactLoadError(f"Unknown build mode {value}.") from error


def _require_physical_object_kind(value: Any) -> PhysicalObjectKind:
    try:
        return PhysicalObjectKind(value)
    except ValueError as error:
        raise GraphqlArtifactLoadError(f"Unknown object kind {value}.") from error


def _require_identity_mode(value: Any) -> GraphqlCatalogIdentityMode:
    try:
        return GraphqlCatalogIdentityMode(value)
    except ValueError as error:
        raise GraphqlArtifactLoadError(f"Unknown identity mode {value}.") from error


def _require_origin(value: Any) -> GraphqlCatalogOrigin:
    try:
        return GraphqlCatalogOrigin(value)
    except ValueError as error:
        raise GraphqlArtifactLoadError(f"Unknown origin {value}.") from error


def _require_field_visibility(value: Any) -> GraphqlCatalogFieldVisibility:
    try:
        return GraphqlCatalogFieldVisibility(value)
    except ValueError as error:
        raise GraphqlArtifactLoadError(f"Unknown field visibility {value}.") from error


def _require_relation_cardinality(value: Any) -> GraphqlCatalogRelationCardinality:
    try:
        return GraphqlCatalogRelationCardinality(value)
    except ValueError as error:
        raise GraphqlArtifactLoadError(f"Unknown relation cardinality {value}.") from error


def _require_pagination_mode(value: Any) -> GraphqlCatalogPaginationMode:
    try:
        return GraphqlCatalogPaginationMode(value)
    except ValueError as error:
        raise GraphqlArtifactLoadError(f"Unknown pagination mode {value}.") from error


def _require_diagnostic_severity(value: Any) -> GraphqlCatalogDiagnosticSeverity:
    try:
        return GraphqlCatalogDiagnosticSeverity(value)
    except ValueError as error:
        raise GraphqlArtifactLoadError(f"Unknown diagnostic severity {value}.") from error