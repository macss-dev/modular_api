"""GraphQL artifact compiler tests for Stage 8."""

from __future__ import annotations

import json
from pathlib import Path
from tempfile import TemporaryDirectory

import pytest
from starlette.testclient import TestClient

from modular_api import ModularApi
from modular_api.core.registry import api_registry
from modular_api.graphql import (
    GraphqlArtifactCompiler,
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
    GraphqlCatalogSource,
    GraphqlOptions,
    GraphqlPublishedObject,
    ReadExecutionContext,
    ReadExecutor,
    RowSet,
    SqlReadCommand,
)
from modular_api.graphql.sqlserver import PhysicalObjectKind


@pytest.fixture(autouse=True)
def _clear_registry() -> None:
    api_registry.clear()


def test_compile_mode_emits_catalog_json_catalog_lock_diagnostics_json_and_schema_graphql() -> None:
    with TemporaryDirectory(prefix="graphql-artifacts-") as output_directory:
        compiler = GraphqlArtifactCompiler(catalog_factory=_catalog_ordered_async)

        bundle = compiler.write_to_directory(output_directory)

        assert bundle.catalog_json
        assert bundle.catalog_lock_json
        assert bundle.diagnostics_json
        assert bundle.schema_graphql
        assert (Path(output_directory) / "catalog.json").is_file()
        assert (Path(output_directory) / "catalog.lock").is_file()
        assert (Path(output_directory) / "diagnostics.json").is_file()
        assert (Path(output_directory) / "schema.graphql").is_file()


def test_emitted_artifacts_are_byte_stable_for_identical_inputs() -> None:
    with TemporaryDirectory(prefix="graphql-artifacts-left-") as left_directory:
        with TemporaryDirectory(prefix="graphql-artifacts-right-") as right_directory:
            GraphqlArtifactCompiler(catalog_factory=_catalog_ordered_async).write_to_directory(left_directory)
            GraphqlArtifactCompiler(catalog_factory=_catalog_ordered_async).write_to_directory(right_directory)

            assert _read_text(left_directory, "catalog.json") == _read_text(right_directory, "catalog.json")
            assert _read_text(left_directory, "catalog.lock") == _read_text(right_directory, "catalog.lock")
            assert _read_text(left_directory, "diagnostics.json") == _read_text(right_directory, "diagnostics.json")
            assert _read_text(left_directory, "schema.graphql") == _read_text(right_directory, "schema.graphql")


def test_catalog_and_diagnostics_artifacts_are_independent_of_source_discovery_order() -> None:
    with TemporaryDirectory(prefix="graphql-artifacts-ordered-") as left_directory:
        with TemporaryDirectory(prefix="graphql-artifacts-reversed-") as right_directory:
            GraphqlArtifactCompiler(catalog_factory=_catalog_ordered_async).write_to_directory(left_directory)
            GraphqlArtifactCompiler(catalog_factory=_catalog_out_of_order_async).write_to_directory(right_directory)

            assert _read_text(left_directory, "catalog.json") == _read_text(right_directory, "catalog.json")
            assert _read_text(left_directory, "diagnostics.json") == _read_text(right_directory, "diagnostics.json")


def test_authoritative_artifacts_omit_volatile_execution_time_data_and_lock_includes_source_digest() -> None:
    with TemporaryDirectory(prefix="graphql-artifacts-") as output_directory:
        GraphqlArtifactCompiler(catalog_factory=_catalog_ordered_async).write_to_directory(output_directory)

        catalog_json = _read_text(output_directory, "catalog.json")
        catalog_lock_json = _read_text(output_directory, "catalog.lock")
        diagnostics_json = _read_text(output_directory, "diagnostics.json")

        assert "generatedAt" not in catalog_json
        assert "generatedAt" not in catalog_lock_json
        assert "generatedAt" not in diagnostics_json

        lock = json.loads(catalog_lock_json)
        assert lock == {
            "catalogVersion": "1.0.0",
            "sourceDigest": "digest-a",
            "providerVersion": "0.4.7-test",
        }


def test_runtime_fast_path_loads_valid_prebuilt_artifacts_successfully() -> None:
    with TemporaryDirectory(prefix="graphql-artifacts-") as output_directory:
        GraphqlArtifactCompiler(catalog_factory=_catalog_ordered_async).write_to_directory(output_directory)
        api = ModularApi(
            base_path="/api",
            title="GraphQL Artifact API",
            version="1.0.0",
            graphql=GraphqlOptions(
                artifact_directory=output_directory,
                source_digest_factory=lambda: "digest-a",
                catalog_factory=_unexpected_catalog_factory,
                executor=_NoopExecutor(),
            ),
        )

        with TestClient(api.build()) as client:
            response = client.post(
                "/api/graphql",
                json={"query": "{ customerRecordList { items { customerId } } }"},
            )

        assert response.status_code == 200
        assert response.json() == {
            "data": {
                "customerRecordList": {
                    "items": [],
                }
            }
        }


def test_drift_between_normalized_inputs_and_catalog_lock_falls_back_to_source_compilation() -> None:
    with TemporaryDirectory(prefix="graphql-artifacts-") as output_directory:
        GraphqlArtifactCompiler(catalog_factory=_catalog_ordered_async).write_to_directory(output_directory)

        compilation_count = 0

        async def _catalog_factory() -> GraphqlCatalog:
            nonlocal compilation_count
            compilation_count += 1
            return _catalog_ordered(source_digest="digest-b")

        api = ModularApi(
            base_path="/api",
            title="GraphQL Artifact API",
            version="1.0.0",
            graphql=GraphqlOptions(
                artifact_directory=output_directory,
                source_digest_factory=lambda: "digest-b",
                catalog_factory=_catalog_factory,
                executor=_NoopExecutor(),
            ),
        )

        with TestClient(api.build()):
            pass

        assert compilation_count == 1


def _read_text(directory: str, file_name: str) -> str:
    return (Path(directory) / file_name).read_text(encoding="utf-8")


def _catalog_ordered(source_digest: str = "digest-a") -> GraphqlCatalog:
    return GraphqlCatalog(
        catalog_version="1.0.0",
        provider=GraphqlCatalogProvider(
            kind="sql",
            engine="sqlserver",
            provider_version="0.4.7-test",
        ),
        build=GraphqlCatalogBuild(
            mode=GraphqlCatalogBuildMode.COMPILE,
            source_root="db/src",
            source_digest=source_digest,
        ),
        objects=(
            _customer_object(),
            _order_object(),
        ),
        diagnostics=(
            GraphqlCatalogDiagnostic(
                severity=GraphqlCatalogDiagnosticSeverity.WARNING,
                code="alpha_warning",
                message="alpha",
            ),
            GraphqlCatalogDiagnostic(
                severity=GraphqlCatalogDiagnosticSeverity.INFO,
                code="beta_info",
                message="beta",
            ),
        ),
    )


async def _catalog_ordered_async() -> GraphqlCatalog:
    return _catalog_ordered()


async def _catalog_out_of_order_async() -> GraphqlCatalog:
    return GraphqlCatalog(
        catalog_version="1.0.0",
        provider=GraphqlCatalogProvider(
            kind="sql",
            engine="sqlserver",
            provider_version="0.4.7-test",
        ),
        build=GraphqlCatalogBuild(
            mode=GraphqlCatalogBuildMode.COMPILE,
            source_root="db/src",
            source_digest="digest-a",
        ),
        objects=(
            _order_object(),
            _customer_object(),
        ),
        diagnostics=(
            GraphqlCatalogDiagnostic(
                severity=GraphqlCatalogDiagnosticSeverity.INFO,
                code="beta_info",
                message="beta",
            ),
            GraphqlCatalogDiagnostic(
                severity=GraphqlCatalogDiagnosticSeverity.WARNING,
                code="alpha_warning",
                message="alpha",
            ),
        ),
    )


async def _unexpected_catalog_factory() -> GraphqlCatalog:
    raise AssertionError("catalog_factory should not run on artifact fast path")


def _customer_object() -> GraphqlPublishedObject:
    return GraphqlPublishedObject(
        id="sales.Customer",
        kind=PhysicalObjectKind.TABLE,
        readonly=True,
        source=GraphqlCatalogSource(
            schema_name="sales",
            object_name="Customer",
        ),
        graphql=GraphqlCatalogGraphqlNames(
            type_name="CustomerRecord",
            collection_field="customerRecordList",
            item_field="customerRecord",
        ),
        identity=GraphqlCatalogIdentity(
            mode=GraphqlCatalogIdentityMode.SINGLE,
            fields=("CustomerId",),
            origin=GraphqlCatalogOrigin.INFERRED,
        ),
        fields=(
            GraphqlCatalogField(
                column="CustomerId",
                public_name="customerId",
                type="Int",
                nullable=False,
                visibility=GraphqlCatalogFieldVisibility.PUBLIC,
                filterable=True,
                sortable=True,
                sensitive=False,
                origin=GraphqlCatalogOrigin.INFERRED,
            ),
            GraphqlCatalogField(
                column="Name",
                public_name="name",
                type="String",
                nullable=False,
                visibility=GraphqlCatalogFieldVisibility.PUBLIC,
                filterable=True,
                sortable=True,
                sensitive=False,
                origin=GraphqlCatalogOrigin.INFERRED,
            ),
        ),
        relations=(),
        capabilities=GraphqlCatalogCapabilities(
            item=True,
            collection=True,
            filter=True,
            sort=True,
            pagination=GraphqlCatalogPagination(
                mode=GraphqlCatalogPaginationMode.OFFSET,
                default_limit=25,
                max_limit=100,
            ),
        ),
    )


def _order_object() -> GraphqlPublishedObject:
    return GraphqlPublishedObject(
        id="sales.Order",
        kind=PhysicalObjectKind.TABLE,
        readonly=True,
        source=GraphqlCatalogSource(
            schema_name="sales",
            object_name="Order",
        ),
        graphql=GraphqlCatalogGraphqlNames(
            type_name="OrderRecord",
            collection_field="orderRecordList",
            item_field="orderRecord",
        ),
        identity=GraphqlCatalogIdentity(
            mode=GraphqlCatalogIdentityMode.SINGLE,
            fields=("OrderId",),
            origin=GraphqlCatalogOrigin.INFERRED,
        ),
        fields=(
            GraphqlCatalogField(
                column="OrderId",
                public_name="orderId",
                type="Int",
                nullable=False,
                visibility=GraphqlCatalogFieldVisibility.PUBLIC,
                filterable=True,
                sortable=True,
                sensitive=False,
                origin=GraphqlCatalogOrigin.INFERRED,
            ),
        ),
        relations=(),
        capabilities=GraphqlCatalogCapabilities(
            item=True,
            collection=True,
            filter=True,
            sort=True,
            pagination=GraphqlCatalogPagination(
                mode=GraphqlCatalogPaginationMode.OFFSET,
                default_limit=25,
                max_limit=100,
            ),
        ),
    )


class _NoopExecutor(ReadExecutor):
    async def execute(
        self,
        command: SqlReadCommand,
        context: ReadExecutionContext,
    ) -> RowSet:
        del command, context
        return RowSet(rows=(), row_count=0)

    async def close(self) -> None:
        return None