"""GraphQL runtime plugin with real execution for Stage 7."""

from __future__ import annotations

import asyncio
import inspect
import json
from dataclasses import dataclass, field
from typing import Any, Callable, TypeAlias, cast

from graphql import (
    GraphQLError,
    GraphQLResolveInfo,
    GraphQLSchema,
    NoSchemaIntrospectionCustomRule,
    build_schema,
    default_field_resolver,
    execute,
    parse,
    specified_rules,
    validate,
)
from graphql.language.ast import DocumentNode, FieldNode, FragmentDefinitionNode, SelectionSetNode

from modular_api.core.health.health_check import HealthCheck, HealthCheckResult, HealthStatus
from modular_api.core.health.health_service import HealthService
from modular_api.core.plugin import Plugin, PluginHost, PluginManifest, PluginRequestContext, PluginValidationResult
from modular_api.graphql.catalog import (
    GraphqlCatalog,
    GraphqlCatalogField,
    GraphqlCatalogRelation,
    GraphqlCatalogRelationCardinality,
    GraphqlPublishedObject,
)
from modular_api.graphql.read import (
    ReadExecutionContext,
    ReadExecutor,
    RowSet,
    SqlCatalogReadDispatcher,
    SqlCollectionSelection,
    SqlCountSelection,
    SqlFilterCondition,
    SqlFilterGroup,
    SqlFilterNode,
    SqlFilterOperator,
    SqlItemSelection,
    SqlOrderByClause,
    SqlPage,
    SqlRelationBatchSelection,
    SqlServerReadCompiler,
    SqlSortDirection,
)
from modular_api.graphql.runtime.graphql_runtime_options import (
    GraphqlOptions,
    GraphqlRequestEvent,
    GraphqlRequestPhase,
    graphql_default_read_executor_capability_id,
)

_OFFICIAL_PLUGIN_HOST_RANGE = ">=0.1.0 <0.2.0"
_GRAPHQL_TOTAL_COUNT_THUNK_KEY = object()
_GRAPHQL_JSON_CONTENT_TYPE = "application/json; charset=utf-8"

RuntimeFieldResolver: TypeAlias = Callable[..., Any]


@dataclass(slots=True)
class _GraphqlReadyState:
    catalog: GraphqlCatalog
    executor: ReadExecutor
    sdl: str
    schema: GraphQLSchema
    dispatcher: SqlCatalogReadDispatcher
    resolvers: dict[str, RuntimeFieldResolver]


@dataclass(slots=True)
class _GraphqlRuntimeState:
    status: str = "disabled"
    ready: _GraphqlReadyState | None = None


@dataclass(slots=True)
class _GraphqlExecutionContext:
    request: PluginRequestContext
    ready_state: _GraphqlReadyState
    relation_loaders: dict[str, _RelationBatchLoader] = field(default_factory=dict)


@dataclass(frozen=True, slots=True)
class _RelationParentKey:
    cache_key: str
    values: dict[str, Any]


class GraphqlRuntimePlugin(Plugin):
    def __init__(self, *, options: GraphqlOptions | None, health_service: HealthService) -> None:
        self.manifest = PluginManifest(
            id="modular_api.graphql",
            display_name="GraphQL Plugin",
            version="0.1.0",
            host_api_version=_OFFICIAL_PLUGIN_HOST_RANGE,
        )
        self._options = options
        self._health_service = health_service
        self._state = _GraphqlRuntimeState()

    def setup(self, host: PluginHost) -> None:
        self._health_service.add_health_check(_GraphqlRuntimeHealthCheck(self._state))

        if self._options is None:
            return

        async def _handler(context: PluginRequestContext) -> dict[str, object]:
            return await self._handle_request(context)

        host.register_route(
            {
                "id": "graphql.endpoint",
                "method": "POST",
                "path": "/graphql",
                "visibility": "transport",
                "handler": _handler,
            }
        )

    def validate(self, host: PluginHost) -> list[PluginValidationResult]:
        if self._options is None:
            return []

        if self._options.max_depth < 1:
            return [self._validation_failure("graphql.maxDepth", "GraphQL max_depth must be greater than or equal to 1.")]

        if self._options.max_complexity < 1:
            return [
                self._validation_failure(
                    "graphql.maxComplexity",
                    "GraphQL max_complexity must be greater than or equal to 1.",
                )
            ]

        if self._options.default_limit < 0:
            return [self._validation_failure("graphql.defaultLimit", "GraphQL default_limit must be non-negative.")]

        if self._options.max_limit < 1:
            return [self._validation_failure("graphql.maxLimit", "GraphQL max_limit must be greater than zero.")]

        if self._options.default_limit > self._options.max_limit:
            return [
                self._validation_failure(
                    "graphql.defaultLimit",
                    "GraphQL default_limit cannot exceed max_limit.",
                )
            ]

        executor = self._resolve_executor(host)
        if isinstance(executor, PluginValidationResult):
            return [executor]

        try:
            catalog = asyncio.run(self._options.catalog_factory())
        except Exception as error:  # noqa: BLE001
            return [self._validation_failure("graphql.catalog", f"GraphQL catalog construction failed: {error}")]

        try:
            sdl = self._options.sdl_factory(catalog)
            _validate_generated_sdl(sdl)
            schema = build_schema(sdl)
        except Exception as error:  # noqa: BLE001
            return [self._validation_failure("graphql.schema", f"GraphQL schema generation failed: {error}")]

        dispatcher = SqlCatalogReadDispatcher(
            compiler=SqlServerReadCompiler(),
            executor=executor,
        )
        self._state.status = "ready"
        self._state.ready = _GraphqlReadyState(
            catalog=catalog,
            executor=executor,
            sdl=sdl,
            schema=schema,
            dispatcher=dispatcher,
            resolvers=_build_resolver_registry(catalog=catalog, dispatcher=dispatcher, options=self._options),
        )
        return []

    async def shutdown(self) -> None:
        self._state.status = "disabled"
        if self._options is not None and self._options.executor is not None:
            await self._options.executor.close()

    def _resolve_executor(self, host: PluginHost) -> ReadExecutor | PluginValidationResult:
        if self._options is None:
            return self._validation_failure(
                graphql_default_read_executor_capability_id,
                "GraphQL runtime is not configured.",
            )

        if self._options.executor is not None:
            return self._options.executor

        capability_id = self._options.execution_capability_id or graphql_default_read_executor_capability_id
        capability = host.resolve_capability(capability_id)
        if capability is None:
            return self._validation_failure(
                capability_id,
                f"Missing GraphQL read executor capability: {capability_id}",
            )
        if not _is_read_executor(capability.value):
            return self._validation_failure(
                capability_id,
                f"Capability {capability_id} does not expose a ReadExecutor.",
            )
        return cast(ReadExecutor, capability.value)

    async def _handle_request(self, context: PluginRequestContext) -> dict[str, object]:
        ready = self._state.ready
        if self._options is None or ready is None:
            return {
                "status": 503,
                "headers": {"content-type": _GRAPHQL_JSON_CONTENT_TYPE},
                "body": {"errors": [{"message": "GraphQL runtime is not initialized."}]},
            }

        await self._emit_event(
            context,
            GraphqlRequestEvent(
                phase=GraphqlRequestPhase.STARTED,
                request_id=context.request_id,
                method=context.method,
                path=context.path,
            ),
        )

        try:
            response = await self._execute_request(context, ready)
            await self._emit_event(
                context,
                GraphqlRequestEvent(
                    phase=GraphqlRequestPhase.COMPLETED,
                    request_id=context.request_id,
                    method=context.method,
                    path=context.path,
                    status_code=int(response["status"]),
                ),
            )
            return response
        except Exception:  # noqa: BLE001
            await self._emit_event(
                context,
                GraphqlRequestEvent(
                    phase=GraphqlRequestPhase.COMPLETED,
                    request_id=context.request_id,
                    method=context.method,
                    path=context.path,
                    status_code=500,
                ),
            )
            raise

    async def _emit_event(self, context: PluginRequestContext, event: GraphqlRequestEvent) -> None:
        if self._options is None or self._options.on_event is None:
            return

        try:
            result = self._options.on_event(event)
            if inspect.isawaitable(result):
                await result
        except Exception as error:  # noqa: BLE001
            if context.logger is not None:
                context.logger.warning(
                    "graphql telemetry hook failed",
                    fields={
                        "request_id": context.request_id,
                        "path": context.path,
                        "error": str(error),
                    },
                )

    async def _execute_request(self, context: PluginRequestContext, ready: _GraphqlReadyState) -> dict[str, object]:
        query = _read_query(context)
        if query is None:
            return {
                "status": 400,
                "headers": {"content-type": _GRAPHQL_JSON_CONTENT_TYPE},
                "body": {"errors": [{"message": "GraphQL request body must include a query string."}]},
            }

        try:
            document = parse(query)
        except Exception as error:  # noqa: BLE001
            return _graphql_ok_response(errors=[_format_graphql_error(error)])

        max_depth = _compute_document_depth(document)
        if max_depth > self._options.max_depth:
            return _graphql_ok_response(
                errors=[
                    _validation_error(
                        f"Maximum operation depth of {self._options.max_depth} reached. Operation depth: {max_depth}.",
                        "queryDepthComplexity",
                    )
                ]
            )

        validation_errors = validate(
            ready.schema,
            document,
            tuple(specified_rules)
            if self._options.introspection_enabled
            else (*specified_rules, NoSchemaIntrospectionCustomRule),
        )
        if validation_errors:
            return _graphql_ok_response(errors=[_format_graphql_error(error) for error in validation_errors])

        complexity = _compute_document_complexity(document)
        if complexity > self._options.max_complexity:
            return _graphql_ok_response(
                errors=[
                    _validation_error(
                        f"Maximum operation complexity of {self._options.max_complexity} reached. Operation complexity: {complexity}.",
                        "queryComplexity",
                    )
                ]
            )

        execution_context = _GraphqlExecutionContext(request=context, ready_state=ready)
        result = execute(
            ready.schema,
            document,
            root_value={},
            context_value=execution_context,
            operation_name=_read_operation_name(context.body),
            variable_values=_read_variables(context.body),
            field_resolver=_field_resolver,
        )
        if inspect.isawaitable(result):
            result = await result

        return _graphql_ok_response(
            data=result.data,
            errors=[_format_graphql_error(error) for error in result.errors] if result.errors else None,
        )

    def _validation_failure(self, resource_id: str, message: str) -> PluginValidationResult:
        return PluginValidationResult(
            code="PLUGIN_VALIDATION_FAILED",
            message=message,
            plugin_id=self.manifest.id,
            resource_id=resource_id,
        )


class _GraphqlRuntimeHealthCheck(HealthCheck):
    def __init__(self, state: _GraphqlRuntimeState) -> None:
        self._state = state

    @property
    def name(self) -> str:
        return "graphql"

    async def check(self) -> HealthCheckResult:
        output = "disabled" if self._state.status == "disabled" else "ready"
        return HealthCheckResult(status=HealthStatus.PASS, output=output)


class _RelationBatchLoader:
    def __init__(
        self,
        *,
        catalog: GraphqlCatalog,
        source_object: GraphqlPublishedObject,
        target_object: GraphqlPublishedObject,
        relation: GraphqlCatalogRelation,
        projected_fields: tuple[str, ...],
        dispatcher: SqlCatalogReadDispatcher,
        request_context: PluginRequestContext,
    ) -> None:
        self._catalog = catalog
        self._source_object = source_object
        self._target_object = target_object
        self._relation = relation
        self._projected_fields = projected_fields
        self._dispatcher = dispatcher
        self._request_context = request_context
        self._cache: dict[str, asyncio.Future[tuple[dict[str, Any], ...]]] = {}
        self._queued_keys: dict[str, _RelationParentKey] = {}
        self._flush_scheduled = False

    async def load(self, key: _RelationParentKey) -> tuple[dict[str, Any], ...]:
        future = self._cache.get(key.cache_key)
        if future is None:
            loop = asyncio.get_running_loop()
            future = loop.create_future()
            self._cache[key.cache_key] = future
            self._queued_keys[key.cache_key] = key
            if not self._flush_scheduled:
                self._flush_scheduled = True
                loop.call_soon(self._schedule_flush)
        return await future

    def _schedule_flush(self) -> None:
        asyncio.create_task(self._flush())

    async def _flush(self) -> None:
        queued_keys = tuple(self._queued_keys.values())
        self._queued_keys = {}
        self._flush_scheduled = False
        try:
            row_set = await self._dispatcher.read_relation_batch(
                catalog=self._catalog,
                selection=SqlRelationBatchSelection(
                    source_object_id=self._source_object.id,
                    relation_name=self._relation.name,
                    projected_fields=self._projected_fields,
                    parent_keys=tuple(key.values for key in queued_keys),
                ),
                context=_build_execution_context(self._request_context),
            )
            grouped_rows = _group_relation_rows(
                row_set=row_set,
                target_object=self._target_object,
                relation=self._relation,
            )
            for key in queued_keys:
                future = self._cache[key.cache_key]
                if not future.done():
                    future.set_result(grouped_rows.get(key.cache_key, ()))
        except Exception as error:  # noqa: BLE001
            for key in queued_keys:
                future = self._cache.pop(key.cache_key, None)
                if future is not None and not future.done():
                    future.set_exception(error)


def _build_resolver_registry(
    *,
    catalog: GraphqlCatalog,
    dispatcher: SqlCatalogReadDispatcher,
    options: GraphqlOptions,
) -> dict[str, RuntimeFieldResolver]:
    resolvers: dict[str, RuntimeFieldResolver] = {}

    for object_ in catalog.objects:
        if object_.graphql.item_field is not None:
            async def _item_resolver(
                source: Any,
                info: GraphQLResolveInfo,
                *,
                _object: GraphqlPublishedObject = object_,
                _dispatcher: SqlCatalogReadDispatcher = dispatcher,
                **args: Any,
            ) -> Any:
                return await _resolve_item(
                    args=args,
                    info=info,
                    catalog=catalog,
                    object_=_object,
                    dispatcher=_dispatcher,
                )

            resolvers[f"Query.{object_.graphql.item_field}"] = _item_resolver

        async def _collection_resolver(
            source: Any,
            info: GraphQLResolveInfo,
            *,
            _object: GraphqlPublishedObject = object_,
            _dispatcher: SqlCatalogReadDispatcher = dispatcher,
            _options: GraphqlOptions = options,
            **args: Any,
        ) -> Any:
            return await _resolve_collection(
                args=args,
                info=info,
                catalog=catalog,
                object_=_object,
                dispatcher=_dispatcher,
                runtime_options=_options,
            )

        resolvers[f"Query.{object_.graphql.collection_field}"] = _collection_resolver

        for relation in object_.relations:
            async def _relation_resolver(
                source: Any,
                info: GraphQLResolveInfo,
                *,
                _source_object: GraphqlPublishedObject = object_,
                _relation: GraphqlCatalogRelation = relation,
                _dispatcher: SqlCatalogReadDispatcher = dispatcher,
                **args: Any,
            ) -> Any:
                return await _resolve_relation(
                    source=source,
                    info=info,
                    catalog=catalog,
                    source_object=_source_object,
                    relation=_relation,
                    dispatcher=_dispatcher,
                )

            resolvers[f"{object_.graphql.type_name}.{relation.name}"] = _relation_resolver

        async def _total_count_resolver(source: Any, info: GraphQLResolveInfo, **args: Any) -> int:
            if not isinstance(source, dict):
                return 0
            thunk = source.get(_GRAPHQL_TOTAL_COUNT_THUNK_KEY)
            if callable(thunk):
                result = thunk()
                if inspect.isawaitable(result):
                    result = await result
                return int(result)
            return 0

        resolvers[f"{object_.graphql.type_name}List.totalCount"] = _total_count_resolver

    return resolvers


async def _field_resolver(source: Any, info: GraphQLResolveInfo, **kwargs: Any) -> Any:
    context = cast(_GraphqlExecutionContext, info.context)
    resolver = context.ready_state.resolvers.get(f"{info.parent_type.name}.{info.field_name}")
    if resolver is not None:
        result = resolver(source, info, **kwargs)
        if inspect.isawaitable(result):
            return await result
        return result
    return default_field_resolver(source, info, **kwargs)


async def _resolve_item(
    *,
    args: dict[str, Any],
    info: GraphQLResolveInfo,
    catalog: GraphqlCatalog,
    object_: GraphqlPublishedObject,
    dispatcher: SqlCatalogReadDispatcher,
) -> Any:
    key = args.get("key")
    if not isinstance(key, dict):
        raise _graphql_validation_error("graphql.key", "GraphQL item queries require a key input object.")

    execution_context = cast(_GraphqlExecutionContext, info.context)
    row_set = await dispatcher.read_item(
        catalog=catalog,
        selection=SqlItemSelection(
            object_id=object_.id,
            projected_fields=_projected_fields_for_object(
                object_=object_,
                field_nodes=info.field_nodes,
                fragments=info.fragments,
            ),
            key=dict(key),
        ),
        context=_build_execution_context(execution_context.request),
    )
    return row_set.rows[0] if row_set.rows else None


async def _resolve_collection(
    *,
    args: dict[str, Any],
    info: GraphQLResolveInfo,
    catalog: GraphqlCatalog,
    object_: GraphqlPublishedObject,
    dispatcher: SqlCatalogReadDispatcher,
    runtime_options: GraphqlOptions,
) -> dict[object, Any]:
    execution_context = cast(_GraphqlExecutionContext, info.context)
    envelope_fields = _collect_selected_field_nodes(info.field_nodes, info.fragments)
    item_field_nodes = tuple(envelope_fields.get("items", ()))
    wants_total_count = "totalCount" in envelope_fields
    filter_node = _parse_filter(object_, args.get("filter"))
    order_by = _parse_order_by(object_, args.get("orderBy"))
    page = _parse_page(object_, args.get("page"), runtime_options)

    items: tuple[dict[str, Any], ...] = ()
    if item_field_nodes and page.limit > 0:
        row_set = await dispatcher.read_collection(
            catalog=catalog,
            selection=SqlCollectionSelection(
                object_id=object_.id,
                projected_fields=_projected_fields_for_object(
                    object_=object_,
                    field_nodes=item_field_nodes,
                    fragments=info.fragments,
                ),
                filter=filter_node,
                order_by=order_by,
                page=page,
            ),
            context=_build_execution_context(execution_context.request),
        )
        items = row_set.rows

    envelope: dict[object, Any] = {"items": items}
    if wants_total_count:
        async def _count_thunk() -> int:
            row_set = await dispatcher.read_count(
                catalog=catalog,
                selection=SqlCountSelection(object_id=object_.id, filter=filter_node),
                context=_build_execution_context(execution_context.request),
            )
            return _extract_total_count(row_set)

        envelope[_GRAPHQL_TOTAL_COUNT_THUNK_KEY] = _count_thunk

    return envelope


async def _resolve_relation(
    *,
    source: Any,
    info: GraphQLResolveInfo,
    catalog: GraphqlCatalog,
    source_object: GraphqlPublishedObject,
    relation: GraphqlCatalogRelation,
    dispatcher: SqlCatalogReadDispatcher,
) -> Any:
    if not isinstance(source, dict):
        if relation.cardinality is GraphqlCatalogRelationCardinality.MANY:
            return ()
        return None

    execution_context = cast(_GraphqlExecutionContext, info.context)
    target_object = _object_by_id(catalog, relation.target)
    projected_fields = _projected_fields_for_object(
        object_=target_object,
        field_nodes=info.field_nodes,
        fragments=info.fragments,
        required_public_fields=tuple(_field_by_column(target_object, column).public_name for column in relation.target_fields),
    )
    parent_values = _relation_parent_values(
        source_object=source_object,
        relation=relation,
        parent=source,
    )
    loader = _relation_loader(
        execution_context=execution_context,
        catalog=catalog,
        source_object=source_object,
        target_object=target_object,
        relation=relation,
        projected_fields=projected_fields,
        dispatcher=dispatcher,
    )
    rows = await loader.load(
        _RelationParentKey(
            cache_key=_relation_key_from_values(parent_values),
            values=dict(parent_values),
        )
    )
    if relation.cardinality is GraphqlCatalogRelationCardinality.MANY:
        return rows
    return rows[0] if rows else None


def _relation_loader(
    *,
    execution_context: _GraphqlExecutionContext,
    catalog: GraphqlCatalog,
    source_object: GraphqlPublishedObject,
    target_object: GraphqlPublishedObject,
    relation: GraphqlCatalogRelation,
    projected_fields: tuple[str, ...],
    dispatcher: SqlCatalogReadDispatcher,
) -> _RelationBatchLoader:
    loader_id = "|".join((source_object.id, relation.name, ",".join(projected_fields)))
    existing = execution_context.relation_loaders.get(loader_id)
    if existing is not None:
        return existing

    loader = _RelationBatchLoader(
        catalog=catalog,
        source_object=source_object,
        target_object=target_object,
        relation=relation,
        projected_fields=projected_fields,
        dispatcher=dispatcher,
        request_context=execution_context.request,
    )
    execution_context.relation_loaders[loader_id] = loader
    return loader


def _projected_fields_for_object(
    *,
    object_: GraphqlPublishedObject,
    field_nodes: tuple[FieldNode, ...] | list[FieldNode],
    fragments: dict[str, FragmentDefinitionNode],
    required_public_fields: tuple[str, ...] = (),
) -> tuple[str, ...]:
    projected = set(required_public_fields)
    for column in object_.identity.fields:
        projected.add(_field_by_column(object_, column).public_name)

    selected = _collect_selected_field_nodes(field_nodes, fragments)
    for field in object_.fields:
        if field.public_name in selected:
            projected.add(field.public_name)

    for relation in object_.relations:
        if relation.name not in selected:
            continue
        for column in relation.source_fields:
            projected.add(_field_by_column(object_, column).public_name)

    return tuple(field.public_name for field in object_.fields if field.public_name in projected)


def _collect_selected_field_nodes(
    field_nodes: tuple[FieldNode, ...] | list[FieldNode],
    fragments: dict[str, FragmentDefinitionNode],
) -> dict[str, tuple[FieldNode, ...]]:
    collected: dict[str, list[FieldNode]] = {}
    visited_fragments: set[str] = set()
    for field_node in field_nodes:
        _collect_selection_set(field_node.selection_set, fragments, collected, visited_fragments)
    return {key: tuple(value) for key, value in collected.items()}


def _collect_selection_set(
    selection_set: SelectionSetNode | None,
    fragments: dict[str, FragmentDefinitionNode],
    collected: dict[str, list[FieldNode]],
    visited_fragments: set[str],
) -> None:
    if selection_set is None:
        return

    for selection in selection_set.selections:
        if selection.kind == "field":
            field = cast(FieldNode, selection)
            collected.setdefault(field.name.value, []).append(field)
            continue
        if selection.kind == "inline_fragment":
            _collect_selection_set(selection.selection_set, fragments, collected, visited_fragments)
            continue
        if selection.kind == "fragment_spread":
            fragment_name = selection.name.value
            if fragment_name in visited_fragments:
                continue
            visited_fragments.add(fragment_name)
            fragment = fragments.get(fragment_name)
            if fragment is not None:
                _collect_selection_set(fragment.selection_set, fragments, collected, visited_fragments)


def _parse_filter(object_: GraphqlPublishedObject, raw: Any) -> SqlFilterNode | None:
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise _graphql_validation_error("graphql.filter", "GraphQL filter input must be an object.")

    nodes: list[SqlFilterNode] = []
    for key, value in raw.items():
        if key == "and":
            children = tuple(child for child in (_parse_filter(object_, item) for item in value or ()) if child is not None)
            if children:
                nodes.append(SqlFilterGroup.and_(children))
            continue
        if key == "or":
            children = tuple(child for child in (_parse_filter(object_, item) for item in value or ()) if child is not None)
            if children:
                nodes.append(SqlFilterGroup.or_(children))
            continue
        if key == "not":
            child = _parse_filter(object_, value)
            if child is not None:
                nodes.append(SqlFilterGroup.not_(child))
            continue

        field = _field_by_public_name(object_, str(key))
        if not field.filterable:
            raise _graphql_validation_error("graphql.filter", f"Field {field.public_name} is not filterable.")
        if not isinstance(value, dict):
            raise _graphql_validation_error(
                "graphql.filter",
                f"Filter operators for {field.public_name} must be an object.",
            )

        conditions = tuple(
            SqlFilterCondition(
                field=field.public_name,
                operator=_parse_filter_operator(str(operator_name)),
                value=operator_value,
            )
            for operator_name, operator_value in value.items()
        )
        if len(conditions) == 1:
            nodes.append(conditions[0])
        elif conditions:
            nodes.append(SqlFilterGroup.and_(conditions))

    if not nodes:
        return None
    return nodes[0] if len(nodes) == 1 else SqlFilterGroup.and_(tuple(nodes))


def _parse_filter_operator(name: str) -> SqlFilterOperator:
    mapping = {
        "eq": SqlFilterOperator.EQ,
        "ne": SqlFilterOperator.NE,
        "in": SqlFilterOperator.IN_LIST,
        "lt": SqlFilterOperator.LT,
        "lte": SqlFilterOperator.LTE,
        "gt": SqlFilterOperator.GT,
        "gte": SqlFilterOperator.GTE,
        "isNull": SqlFilterOperator.IS_NULL,
        "contains": SqlFilterOperator.CONTAINS,
        "startsWith": SqlFilterOperator.STARTS_WITH,
        "endsWith": SqlFilterOperator.ENDS_WITH,
    }
    if name not in mapping:
        raise _graphql_validation_error("graphql.filter", f"Unsupported filter operator {name}.")
    return mapping[name]


def _parse_order_by(object_: GraphqlPublishedObject, raw: Any) -> tuple[SqlOrderByClause, ...]:
    if raw is None:
        return ()
    if not isinstance(raw, list):
        raise _graphql_validation_error("graphql.orderBy", "GraphQL orderBy input must be a list.")

    clauses: list[SqlOrderByClause] = []
    for entry in raw:
        if not isinstance(entry, dict):
            raise _graphql_validation_error("graphql.orderBy", "Each orderBy entry must be an object.")
        field_name = entry.get("field")
        direction = entry.get("direction")
        if not isinstance(field_name, str) or not isinstance(direction, str):
            raise _graphql_validation_error(
                "graphql.orderBy",
                "Each orderBy entry must define field and direction.",
            )

        field = _field_by_public_name(object_, field_name)
        if not field.sortable:
            raise _graphql_validation_error("graphql.orderBy", f"Field {field.public_name} is not sortable.")
        clauses.append(
            SqlOrderByClause(
                field=field.public_name,
                direction=SqlSortDirection.DESC if direction == "DESC" else SqlSortDirection.ASC,
            )
        )

    return tuple(clauses)


def _parse_page(object_: GraphqlPublishedObject, raw: Any, options: GraphqlOptions) -> SqlPage:
    effective_max = min(object_.capabilities.pagination.max_limit, options.max_limit)
    effective_default = min(object_.capabilities.pagination.default_limit, options.default_limit, effective_max)

    if raw is None:
        return SqlPage(limit=effective_default, offset=0)
    if not isinstance(raw, dict):
        raise _graphql_validation_error("graphql.page", "GraphQL page input must be an object.")

    limit = raw.get("limit", effective_default)
    offset = raw.get("offset", 0)
    if not isinstance(limit, int) or not isinstance(offset, int):
        raise _graphql_validation_error("graphql.page", "GraphQL page limit and offset must be integers.")
    if limit < 0 or offset < 0:
        raise _graphql_validation_error("graphql.page", "GraphQL page limit and offset must be non-negative.")
    if limit > effective_max:
        raise _graphql_validation_error(
            "graphql.page",
            f"Requested page limit {limit} exceeds the effective max limit {effective_max}.",
        )
    return SqlPage(limit=limit, offset=offset)


def _build_execution_context(context: PluginRequestContext) -> ReadExecutionContext:
    return ReadExecutionContext(
        request_id=_header_value(context, "x-request-id") or context.request_id,
        tenant_id=_header_value(context, "x-tenant-id"),
        principal=_header_value(context, "x-principal"),
        telemetry=context.logger,
    )


def _header_value(context: PluginRequestContext, name: str) -> str | None:
    for key, value in context.headers.items():
        if key.lower() == name:
            return value
    return None


def _group_relation_rows(
    *,
    row_set: RowSet,
    target_object: GraphqlPublishedObject,
    relation: GraphqlCatalogRelation,
) -> dict[str, tuple[dict[str, Any], ...]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for row in row_set.rows:
        key_values = {
            _field_by_column(target_object, column).public_name: row[_field_by_column(target_object, column).public_name]
            for column in relation.target_fields
        }
        grouped.setdefault(_relation_key_from_values(key_values), []).append(row)
    return {key: tuple(value) for key, value in grouped.items()}


def _relation_parent_values(
    *,
    source_object: GraphqlPublishedObject,
    relation: GraphqlCatalogRelation,
    parent: dict[str, Any],
) -> dict[str, Any]:
    return {
        _field_by_column(source_object, column).public_name: parent[_field_by_column(source_object, column).public_name]
        for column in relation.source_fields
    }


def _relation_key_from_values(values: dict[str, Any]) -> str:
    return json.dumps([(key, values[key]) for key in sorted(values)], default=str)


def _extract_total_count(row_set: RowSet) -> int:
    if not row_set.rows:
        return 0
    value = row_set.rows[0].get("totalCount")
    if isinstance(value, (int, float)):
        return int(value)
    raise ValueError(f"Expected totalCount to be numeric, got {value!r}.")


def _field_by_column(object_: GraphqlPublishedObject, column: str) -> GraphqlCatalogField:
    for field in object_.fields:
        if field.column == column:
            return field
    raise ValueError(f"Unknown source column {column} for {object_.id}.")


def _field_by_public_name(object_: GraphqlPublishedObject, public_name: str) -> GraphqlCatalogField:
    for field in object_.fields:
        if field.public_name == public_name:
            return field
    raise ValueError(f"Unknown public field {public_name} for {object_.id}.")


def _object_by_id(catalog: GraphqlCatalog, object_id: str) -> GraphqlPublishedObject:
    for object_ in catalog.objects:
        if object_.id == object_id:
            return object_
    raise ValueError(f"Unknown catalog object {object_id}.")


def _read_query(context: PluginRequestContext) -> str | None:
    if isinstance(context.body, dict) and isinstance(context.body.get("query"), str):
        return cast(str, context.body["query"])
    query = context.query.get("query")
    return query if isinstance(query, str) else None


def _read_operation_name(body: Any) -> str | None:
    if isinstance(body, dict) and isinstance(body.get("operationName"), str):
        return cast(str, body["operationName"])
    return None


def _read_variables(body: Any) -> dict[str, Any] | None:
    if isinstance(body, dict) and isinstance(body.get("variables"), dict):
        return dict(cast(dict[str, Any], body["variables"]))
    return None


def _compute_document_depth(document: DocumentNode) -> int:
    fragments = _collect_fragments(document)
    max_depth = 0
    for definition in document.definitions:
        if definition.kind != "operation_definition":
            continue
        max_depth = max(max_depth, _selection_set_depth(definition.selection_set, fragments, set(), 0))
    return max_depth


def _selection_set_depth(
    selection_set: SelectionSetNode,
    fragments: dict[str, FragmentDefinitionNode],
    visited_fragments: set[str],
    current_depth: int,
) -> int:
    max_depth = current_depth
    for selection in selection_set.selections:
        if selection.kind == "field":
            next_depth = current_depth + 1
            max_depth = max(max_depth, next_depth)
            if selection.selection_set is not None:
                max_depth = max(
                    max_depth,
                    _selection_set_depth(selection.selection_set, fragments, visited_fragments, next_depth),
                )
            continue
        if selection.kind == "inline_fragment":
            max_depth = max(max_depth, _selection_set_depth(selection.selection_set, fragments, visited_fragments, current_depth))
            continue
        if selection.kind == "fragment_spread":
            fragment_name = selection.name.value
            if fragment_name in visited_fragments:
                continue
            visited_fragments.add(fragment_name)
            fragment = fragments.get(fragment_name)
            if fragment is not None:
                max_depth = max(max_depth, _selection_set_depth(fragment.selection_set, fragments, visited_fragments, current_depth))
    return max_depth


def _compute_document_complexity(document: DocumentNode) -> int:
    fragments = _collect_fragments(document)
    complexity = 0
    for definition in document.definitions:
        if definition.kind != "operation_definition":
            continue
        complexity += _selection_set_complexity(definition.selection_set, fragments, set(), 1)
    return complexity


def _selection_set_complexity(
    selection_set: SelectionSetNode,
    fragments: dict[str, FragmentDefinitionNode],
    visited_fragments: set[str],
    current_depth: int,
) -> int:
    complexity = 0
    for selection in selection_set.selections:
        if selection.kind == "field":
            complexity += current_depth
            if selection.selection_set is not None:
                complexity += _selection_set_complexity(selection.selection_set, fragments, visited_fragments, current_depth + 1)
            continue
        if selection.kind == "inline_fragment":
            complexity += _selection_set_complexity(selection.selection_set, fragments, visited_fragments, current_depth)
            continue
        if selection.kind == "fragment_spread":
            fragment_name = selection.name.value
            if fragment_name in visited_fragments:
                continue
            visited_fragments.add(fragment_name)
            fragment = fragments.get(fragment_name)
            if fragment is not None:
                complexity += _selection_set_complexity(fragment.selection_set, fragments, visited_fragments, current_depth)
    return complexity


def _collect_fragments(document: DocumentNode) -> dict[str, FragmentDefinitionNode]:
    return {
        definition.name.value: definition
        for definition in document.definitions
        if definition.kind == "fragment_definition"
    }


def _graphql_ok_response(*, data: Any = None, errors: list[dict[str, Any]] | None = None) -> dict[str, object]:
    body: dict[str, Any] = {}
    if data is not None:
        body["data"] = data
    if errors is not None:
        body["errors"] = errors
    return {
        "status": 200,
        "headers": {"content-type": _GRAPHQL_JSON_CONTENT_TYPE},
        "body": body,
    }


def _validation_error(message: str, code: str) -> dict[str, Any]:
    return {
        "message": message,
        "extensions": {"validationError": {"code": code}},
    }


def _format_graphql_error(error: Any) -> dict[str, Any]:
    if isinstance(error, GraphQLError):
        return dict(error.formatted)
    if isinstance(error, Exception):
        return {"message": str(error)}
    return {"message": str(error)}


def _graphql_validation_error(code: str, message: str) -> GraphQLError:
    return GraphQLError(message, extensions={"code": code})


def _is_read_executor(value: Any) -> bool:
    return hasattr(value, "execute") and callable(value.execute)


def _validate_generated_sdl(sdl: str) -> None:
    if not sdl.strip():
        raise ValueError("Generated SDL must not be empty.")
    if "type Query {" not in sdl:
        raise ValueError("Generated SDL must declare a Query root type.")

    depth = 0
    for char in sdl:
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth < 0:
                raise ValueError("Generated SDL has unmatched closing brace.")
    if depth != 0:
        raise ValueError("Generated SDL has unmatched opening brace.")