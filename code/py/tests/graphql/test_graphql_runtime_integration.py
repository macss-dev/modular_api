"""GraphQL runtime integration tests for Stage 6."""

from __future__ import annotations

import pytest
from starlette.testclient import TestClient

from modular_api import Capability, ModularApi, Plugin, PluginHost, PluginHostError, PluginManifest
from modular_api.core.registry import api_registry
from modular_api.graphql import (
    GraphqlCatalog,
    GraphqlCatalogBuild,
    GraphqlCatalogBuildMode,
    GraphqlCatalogCapabilities,
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


def test_health_reports_graphql_disabled_and_endpoint_is_absent_by_default() -> None:
    api = ModularApi(
        base_path="/api",
        title="GraphQL Test API",
        version="1.0.0",
    )

    with TestClient(api.build()) as client:
        graphql_response = client.post("/api/graphql", json={"query": "{ __typename }"})
        assert graphql_response.status_code == 404

        health_response = client.get("/api/health")
        assert health_response.status_code == 200
        health_json = health_response.json()
        assert health_json["checks"]["graphql"]["status"] == "pass"
        assert health_json["checks"]["graphql"]["output"] == "disabled"


def test_graphql_options_defaults_introspection_false_max_depth_8_and_max_complexity_500() -> None:
    options = GraphqlOptions(
        catalog_factory=_catalog_fixture_async,
        executor=_NoopExecutor(),
    )

    assert options.introspection_enabled is False
    assert options.max_depth == 8
    assert options.max_complexity == 500
    assert options.default_limit == 50
    assert options.max_limit == 200
    assert options.execution_capability_id is None


def test_graphql_endpoint_mounts_under_base_path_and_health_reports_ready_when_startup_succeeds() -> None:
    api = ModularApi(
        base_path="/api",
        title="GraphQL Test API",
        version="1.0.0",
        graphql=GraphqlOptions(
            catalog_factory=_catalog_fixture_async,
            execution_capability_id="modular_api.sql.read_executor",
        ),
    ).plugin(
        _ExecutorCapabilityPlugin(
            id="acme.sql.read-executor",
            capability_id="modular_api.sql.read_executor",
            executor=_NoopExecutor(),
        )
    )

    with TestClient(api.build()) as client:
        graphql_response = client.post("/api/graphql", json={"query": "{ __typename }"})
        assert graphql_response.status_code == 200
        assert graphql_response.json() == {"data": {"__typename": "Query"}}

        health_response = client.get("/api/health")
        assert health_response.status_code == 200
        health_json = health_response.json()
        assert health_json["checks"]["graphql"]["status"] == "pass"
        assert health_json["checks"]["graphql"]["output"] == "ready"


def test_startup_fails_when_catalog_construction_fails() -> None:
    api = ModularApi(
        base_path="/api",
        graphql=GraphqlOptions(
            catalog_factory=_failing_catalog_factory,
            executor=_NoopExecutor(),
        ),
    )

    with pytest.raises(PluginHostError) as excinfo:
        api.build()

    assert excinfo.value.code == "PLUGIN_VALIDATION_FAILED"
    assert excinfo.value.resource_id == "graphql.catalog"


def test_startup_fails_when_executor_capability_is_missing() -> None:
    api = ModularApi(
        base_path="/api",
        graphql=GraphqlOptions(
            catalog_factory=_catalog_fixture_async,
            execution_capability_id="missing.sql.read_executor",
        ),
    )

    with pytest.raises(PluginHostError) as excinfo:
        api.build()

    assert excinfo.value.code == "PLUGIN_VALIDATION_FAILED"
    assert excinfo.value.resource_id == "missing.sql.read_executor"


def test_startup_fails_when_schema_generation_fails() -> None:
    api = ModularApi(
        base_path="/api",
        graphql=GraphqlOptions(
            catalog_factory=_catalog_fixture_async,
            executor=_NoopExecutor(),
            sdl_factory=lambda _: "type Query {",
        ),
    )

    with pytest.raises(PluginHostError) as excinfo:
        api.build()

    assert excinfo.value.code == "PLUGIN_VALIDATION_FAILED"
    assert excinfo.value.resource_id == "graphql.schema"


def test_startup_fails_when_max_depth_is_invalid() -> None:
    api = ModularApi(
        base_path="/api",
        graphql=GraphqlOptions(
            catalog_factory=_catalog_fixture_async,
            executor=_NoopExecutor(),
            max_depth=0,
        ),
    )

    with pytest.raises(PluginHostError) as excinfo:
        api.build()

    assert excinfo.value.code == "PLUGIN_VALIDATION_FAILED"
    assert excinfo.value.resource_id == "graphql.maxDepth"


def test_startup_fails_when_max_complexity_is_invalid() -> None:
    api = ModularApi(
        base_path="/api",
        graphql=GraphqlOptions(
            catalog_factory=_catalog_fixture_async,
            executor=_NoopExecutor(),
            max_complexity=-1,
        ),
    )

    with pytest.raises(PluginHostError) as excinfo:
        api.build()

    assert excinfo.value.code == "PLUGIN_VALIDATION_FAILED"
    assert excinfo.value.resource_id == "graphql.maxComplexity"


def test_startup_fails_when_default_limit_is_invalid() -> None:
    api = ModularApi(
        base_path="/api",
        graphql=GraphqlOptions(
            catalog_factory=_catalog_fixture_async,
            executor=_NoopExecutor(),
            default_limit=-1,
        ),
    )

    with pytest.raises(PluginHostError) as excinfo:
        api.build()

    assert excinfo.value.code == "PLUGIN_VALIDATION_FAILED"
    assert excinfo.value.resource_id == "graphql.defaultLimit"


def test_startup_fails_when_max_limit_is_invalid() -> None:
    api = ModularApi(
        base_path="/api",
        graphql=GraphqlOptions(
            catalog_factory=_catalog_fixture_async,
            executor=_NoopExecutor(),
            max_limit=0,
        ),
    )

    with pytest.raises(PluginHostError) as excinfo:
        api.build()

    assert excinfo.value.code == "PLUGIN_VALIDATION_FAILED"
    assert excinfo.value.resource_id == "graphql.maxLimit"


def test_startup_fails_when_default_limit_exceeds_max_limit() -> None:
    api = ModularApi(
        base_path="/api",
        graphql=GraphqlOptions(
            catalog_factory=_catalog_fixture_async,
            executor=_NoopExecutor(),
            default_limit=40,
            max_limit=20,
        ),
    )

    with pytest.raises(PluginHostError) as excinfo:
        api.build()

    assert excinfo.value.code == "PLUGIN_VALIDATION_FAILED"
    assert excinfo.value.resource_id == "graphql.defaultLimit"


def test_direct_executor_and_capability_id_are_mutually_exclusive() -> None:
    with pytest.raises(ValueError):
        GraphqlOptions(
            catalog_factory=_catalog_fixture_async,
            executor=_NoopExecutor(),
            execution_capability_id="modular_api.sql.read_executor",
        )


async def _catalog_fixture_async() -> GraphqlCatalog:
    return _catalog_fixture()


async def _failing_catalog_factory() -> GraphqlCatalog:
    raise RuntimeError("introspection failed")


def _catalog_fixture() -> GraphqlCatalog:
    return GraphqlCatalog(
        catalog_version="1.0.0",
        provider=GraphqlCatalogProvider(
            kind="sql",
            engine="sqlserver",
            provider_version="0.4.7-test",
        ),
        build=GraphqlCatalogBuild(
            mode=GraphqlCatalogBuildMode.RUNTIME,
            source_root="db/src",
            source_digest="test-digest",
        ),
        objects=(
            GraphqlPublishedObject(
                id="sales.Customer",
                kind=PhysicalObjectKind.TABLE,
                readonly=True,
                source=GraphqlCatalogSource(schema_name="sales", object_name="Customer"),
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
            ),
        ),
        diagnostics=(),
    )


class _ExecutorCapabilityPlugin(Plugin):
    def __init__(self, *, id: str, capability_id: str, executor: ReadExecutor) -> None:
        self.manifest = PluginManifest(
            id=id,
            display_name="Executor Capability Plugin",
            version="0.1.0",
            host_api_version=">=0.1.0 <0.2.0",
        )
        self._capability_id = capability_id
        self._executor = executor

    def setup(self, host: PluginHost) -> None:
        host.expose_capability(
            Capability(
                id=self._capability_id,
                version="1.0.0",
                value=self._executor,
            )
        )


class _NoopExecutor(ReadExecutor):
    async def execute(self, command: SqlReadCommand, context: ReadExecutionContext) -> RowSet:
        return RowSet(rows=(), row_count=0)

    async def close(self) -> None:
        return None