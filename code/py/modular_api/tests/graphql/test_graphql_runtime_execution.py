"""GraphQL runtime execution tests for Stage 7."""

from __future__ import annotations

from dataclasses import dataclass

import pytest
from starlette.testclient import TestClient

from modular_api import ModularApi
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
    GraphqlCatalogRelation,
    GraphqlCatalogRelationCardinality,
    GraphqlCatalogSource,
    GraphqlOptions,
    GraphqlPublishedObject,
    ReadExecutionContext,
    ReadExecutor,
    RowSet,
    SqlReadCommand,
    SqlReadCommandPurpose,
)
from modular_api.graphql.sqlserver import PhysicalObjectKind


@pytest.fixture(autouse=True)
def _clear_registry() -> None:
    api_registry.clear()


def test_relation_resolution_batches_one_command_for_many_parents() -> None:
    executor = _RecordingExecutor()
    api = _build_api(executor=executor)

    with TestClient(api.build()) as client:
        response = client.post(
            "/api/graphql",
            json={"query": "{ customerRecordList { items { customerId name orders { orderId customerId } } } }"},
        )

    assert response.status_code == 200
    assert response.json() == {
        "data": {
            "customerRecordList": {
                "items": [
                    {
                        "customerId": 1,
                        "name": "Ada",
                        "orders": [
                            {"orderId": 10, "customerId": 1},
                            {"orderId": 11, "customerId": 1},
                        ],
                    },
                    {
                        "customerId": 2,
                        "name": "Linus",
                        "orders": [{"orderId": 20, "customerId": 2}],
                    },
                ],
            }
        }
    }
    assert _command_count(executor, SqlReadCommandPurpose.COLLECTION) == 1
    assert _command_count(executor, SqlReadCommandPurpose.RELATION_BATCH) == 1


def test_total_count_runs_only_when_selected() -> None:
    executor = _RecordingExecutor()
    api = _build_api(executor=executor)

    with TestClient(api.build()) as client:
        without_count = client.post(
            "/api/graphql",
            json={"query": "{ customerRecordList { items { customerId } } }"},
        )
        assert without_count.status_code == 200
        assert _command_count(executor, SqlReadCommandPurpose.COUNT) == 0

        executor.reset()

        with_count = client.post(
            "/api/graphql",
            json={"query": "{ customerRecordList { items { customerId } totalCount } }"},
        )

    assert with_count.status_code == 200
    assert _command_count(executor, SqlReadCommandPurpose.COLLECTION) == 1
    assert _command_count(executor, SqlReadCommandPurpose.COUNT) == 1
    assert with_count.json() == {
        "data": {
            "customerRecordList": {
                "items": [{"customerId": 1}, {"customerId": 2}],
                "totalCount": 2,
            }
        }
    }


def test_app_pagination_narrows_catalog_defaults_and_omitted_page_uses_effective_default() -> None:
    executor = _RecordingExecutor()
    api = _build_api(
        executor=executor,
        default_limit=20,
        max_limit=80,
    )

    with TestClient(api.build()) as client:
        response = client.post(
            "/api/graphql",
            json={"query": "{ customerRecordList { items { customerId } } }"},
        )

    assert response.status_code == 200
    collection_command = _single_command(executor, SqlReadCommandPurpose.COLLECTION)
    assert [parameter.value for parameter in collection_command.parameters] == [0, 20]


def test_client_page_limit_above_effective_max_fails_validation_instead_of_clamping() -> None:
    executor = _RecordingExecutor()
    api = _build_api(
        executor=executor,
        default_limit=20,
        max_limit=80,
    )

    with TestClient(api.build()) as client:
        response = client.post(
            "/api/graphql",
            json={"query": "{ customerRecordList(page: { limit: 90 }) { items { customerId } } }"},
        )

    assert response.status_code == 200
    assert "effective max limit" in response.json()["errors"][0]["message"]
    assert executor.commands == []


def test_negative_page_values_fail_validation_and_offset_defaults_to_zero() -> None:
    executor = _RecordingExecutor()
    api = _build_api(executor=executor)

    with TestClient(api.build()) as client:
        negative_response = client.post(
            "/api/graphql",
            json={"query": "{ customerRecordList(page: { limit: -1, offset: -2 }) { items { customerId } } }"},
        )
        assert negative_response.status_code == 200
        assert "must be non-negative" in negative_response.json()["errors"][0]["message"]
        assert executor.commands == []

        executor.reset()

        offset_default_response = client.post(
            "/api/graphql",
            json={"query": "{ customerRecordList(page: { limit: 5 }) { items { customerId } } }"},
        )

    assert offset_default_response.status_code == 200
    collection_command = _single_command(executor, SqlReadCommandPurpose.COLLECTION)
    assert [parameter.value for parameter in collection_command.parameters] == [0, 5]


def test_page_limit_zero_yields_empty_items_and_still_allows_total_count() -> None:
    executor = _RecordingExecutor()
    api = _build_api(executor=executor)

    with TestClient(api.build()) as client:
        response = client.post(
            "/api/graphql",
            json={"query": "{ customerRecordList(page: { limit: 0 }) { items { customerId } totalCount } }"},
        )

    assert response.status_code == 200
    assert response.json() == {
        "data": {
            "customerRecordList": {
                "items": [],
                "totalCount": 2,
            }
        }
    }
    assert _command_count(executor, SqlReadCommandPurpose.COLLECTION) == 0
    assert _command_count(executor, SqlReadCommandPurpose.COUNT) == 1


def test_request_scoped_execution_context_reaches_executor() -> None:
    executor = _RecordingExecutor()
    api = _build_api(executor=executor)

    with TestClient(api.build()) as client:
        response = client.post(
            "/api/graphql",
            headers={
                "X-Request-ID": "req-123",
                "X-Tenant-ID": "tenant-a",
                "X-Principal": "user-a",
            },
            json={"query": "{ customerRecordList { items { customerId } } }"},
        )

    assert response.status_code == 200
    context = executor.contexts[0]
    assert context.request_id == "req-123"
    assert context.tenant_id == "tenant-a"
    assert context.principal == "user-a"


def test_query_depth_limits_are_enforced() -> None:
    executor = _RecordingExecutor()
    api = _build_api(
        executor=executor,
        max_depth=2,
        max_complexity=500,
    )

    with TestClient(api.build()) as client:
        response = client.post(
            "/api/graphql",
            json={"query": "{ customerRecordList { items { orders { orderId } } } }"},
        )

    assert response.status_code == 200
    assert response.json()["errors"][0]["extensions"]["validationError"]["code"] == "queryDepthComplexity"
    assert executor.commands == []


def test_query_complexity_limits_are_enforced() -> None:
    executor = _RecordingExecutor()
    api = _build_api(
        executor=executor,
        max_depth=8,
        max_complexity=5,
    )

    with TestClient(api.build()) as client:
        response = client.post(
            "/api/graphql",
            json={"query": "{ customerRecordList { items { customerId } } }"},
        )

    assert response.status_code == 200
    assert response.json()["errors"][0]["extensions"]["validationError"]["code"] == "queryComplexity"
    assert executor.commands == []


def test_introspection_when_enabled_remains_subject_to_the_same_limits() -> None:
    executor = _RecordingExecutor()
    api = _build_api(
        executor=executor,
        introspection_enabled=True,
        max_depth=1,
    )

    with TestClient(api.build()) as client:
        response = client.post(
            "/api/graphql",
            json={"query": "{ __schema { queryType { name } } }"},
        )

    assert response.status_code == 200
    assert response.json()["errors"][0]["extensions"]["validationError"]["code"] == "queryDepthComplexity"
    assert executor.commands == []


def test_telemetry_hook_captures_graphql_request_lifecycle_events() -> None:
    executor = _RecordingExecutor()
    events: list[_EventSnapshot] = []
    api = _build_api(
        executor=executor,
        on_event=lambda event: events.append(
            _EventSnapshot(
                phase=str(event.phase),
                request_id=event.request_id,
                status_code=event.status_code,
            )
        ),
    )

    with TestClient(api.build()) as client:
        response = client.post(
            "/api/graphql",
            headers={"X-Request-ID": "req-telemetry"},
            json={"query": "{ customerRecordList { items { customerId } } }"},
        )

    assert response.status_code == 200
    assert events == [
        _EventSnapshot(phase="started", request_id="req-telemetry", status_code=None),
        _EventSnapshot(phase="completed", request_id="req-telemetry", status_code=200),
    ]


def _build_api(
    *,
    executor: ReadExecutor,
    max_depth: int = 8,
    max_complexity: int = 500,
    default_limit: int = 50,
    max_limit: int = 200,
    introspection_enabled: bool = False,
    on_event: object | None = None,
) -> ModularApi:
    return ModularApi(
        base_path="/api",
        title="GraphQL Runtime API",
        version="1.0.0",
        graphql=GraphqlOptions(
            catalog_factory=_catalog_fixture_async,
            executor=executor,
            introspection_enabled=introspection_enabled,
            max_depth=max_depth,
            max_complexity=max_complexity,
            default_limit=default_limit,
            max_limit=max_limit,
            on_event=on_event,
        ),
    )


async def _catalog_fixture_async() -> GraphqlCatalog:
    return _catalog_fixture()


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
            source_digest="execution-test-digest",
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
                relations=(
                    GraphqlCatalogRelation(
                        name="orders",
                        target="sales.Order",
                        cardinality=GraphqlCatalogRelationCardinality.MANY,
                        source_fields=("CustomerId",),
                        target_fields=("CustomerId",),
                        origin=GraphqlCatalogOrigin.INFERRED,
                    ),
                ),
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
            GraphqlPublishedObject(
                id="sales.Order",
                kind=PhysicalObjectKind.TABLE,
                readonly=True,
                source=GraphqlCatalogSource(schema_name="sales", object_name="Order"),
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


@dataclass(frozen=True, slots=True)
class _EventSnapshot:
    phase: str
    request_id: str
    status_code: int | None


class _RecordingExecutor(ReadExecutor):
    def __init__(self) -> None:
        self.commands: list[SqlReadCommand] = []
        self.contexts: list[ReadExecutionContext] = []

    async def execute(self, command: SqlReadCommand, context: ReadExecutionContext) -> RowSet:
        self.commands.append(command)
        self.contexts.append(context)

        if command.purpose is SqlReadCommandPurpose.COLLECTION and "[sales].[Customer]" in command.sql:
            offset = int(command.parameters[0].value)
            limit = int(command.parameters[1].value)
            rows = tuple(_CUSTOMERS[offset : offset + limit])
            return RowSet(rows=rows, row_count=len(rows))

        if command.purpose is SqlReadCommandPurpose.COUNT and "[sales].[Customer]" in command.sql:
            return RowSet(rows=({"totalCount": 2},), row_count=1)

        if command.purpose is SqlReadCommandPurpose.RELATION_BATCH and "[sales].[Order]" in command.sql:
            parent_customer_ids = {int(parameter.value) for parameter in command.parameters}
            rows = tuple(row for row in _ORDERS if int(row["customerId"]) in parent_customer_ids)
            return RowSet(rows=rows, row_count=len(rows))

        raise AssertionError(f"Unexpected command: {command.purpose} {command.sql}")

    def reset(self) -> None:
        self.commands.clear()
        self.contexts.clear()


def _command_count(executor: _RecordingExecutor, purpose: SqlReadCommandPurpose) -> int:
    return sum(1 for command in executor.commands if command.purpose is purpose)


def _single_command(executor: _RecordingExecutor, purpose: SqlReadCommandPurpose) -> SqlReadCommand:
    return next(command for command in executor.commands if command.purpose is purpose)


_CUSTOMERS = (
    {"customerId": 1, "name": "Ada"},
    {"customerId": 2, "name": "Linus"},
)

_ORDERS = (
    {"orderId": 10, "customerId": 1},
    {"orderId": 11, "customerId": 1},
    {"orderId": 20, "customerId": 2},
)