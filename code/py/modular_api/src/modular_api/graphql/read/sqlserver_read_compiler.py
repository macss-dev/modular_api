"""SQL Server read compiler and dispatcher for Stage 5."""

from __future__ import annotations

from modular_api.graphql.catalog import (
    GraphqlCatalog,
    GraphqlCatalogField,
    GraphqlCatalogRelation,
    GraphqlPublishedObject,
)
from modular_api.graphql.read.sql_read_contract import (
    ReadExecutionContext,
    ReadExecutor,
    RowSet,
    SqlCollectionSelection,
    SqlCountSelection,
    SqlFilterCondition,
    SqlFilterGroup,
    SqlFilterGroupKind,
    SqlFilterNode,
    SqlFilterOperator,
    SqlItemSelection,
    SqlOrderByClause,
    SqlPage,
    SqlParameter,
    SqlReadCommand,
    SqlReadCommandPurpose,
    SqlRelationBatchSelection,
    SqlSortDirection,
)


class SqlServerReadCompiler:
    def compile_item(
        self,
        *,
        catalog: GraphqlCatalog,
        selection: SqlItemSelection,
    ) -> SqlReadCommand:
        object_ = self._resolve_object(catalog, selection.object_id)
        parameters = _SqlParameterBuilder()
        select_list = self._build_select_list(object_, selection.projected_fields)
        where_clause = self._compile_key_predicate(
            object_=object_,
            public_key_values=selection.key,
            parameters=parameters,
        )
        return SqlReadCommand(
            engine="sqlserver",
            sql=f"SELECT TOP (1) {select_list} FROM {self._table_ref(object_)} WHERE {where_clause}",
            parameters=parameters.build(),
            purpose=SqlReadCommandPurpose.ITEM,
        )

    def compile_collection(
        self,
        *,
        catalog: GraphqlCatalog,
        selection: SqlCollectionSelection,
    ) -> SqlReadCommand:
        object_ = self._resolve_object(catalog, selection.object_id)
        parameters = _SqlParameterBuilder()
        sql = (
            f"SELECT {self._build_select_list(object_, selection.projected_fields)} "
            f"FROM {self._table_ref(object_)}"
        )
        where_clause = self._compile_filter(
            object_=object_,
            filter_=selection.filter,
            parameters=parameters,
        )
        if where_clause is not None:
            sql += f" WHERE {where_clause}"
        if selection.order_by:
            sql += f" ORDER BY {self._build_order_by(object_, selection.order_by)}"
        if selection.page is not None:
            offset_name = parameters.add(selection.page.offset, type_="Int")
            limit_name = parameters.add(selection.page.limit, type_="Int")
            sql += f" OFFSET @{offset_name} ROWS FETCH NEXT @{limit_name} ROWS ONLY"
        return SqlReadCommand(
            engine="sqlserver",
            sql=sql,
            parameters=parameters.build(),
            purpose=SqlReadCommandPurpose.COLLECTION,
        )

    def compile_count(
        self,
        *,
        catalog: GraphqlCatalog,
        selection: SqlCountSelection,
    ) -> SqlReadCommand:
        object_ = self._resolve_object(catalog, selection.object_id)
        parameters = _SqlParameterBuilder()
        sql = f"SELECT COUNT_BIG(1) AS [totalCount] FROM {self._table_ref(object_)}"
        where_clause = self._compile_filter(
            object_=object_,
            filter_=selection.filter,
            parameters=parameters,
        )
        if where_clause is not None:
            sql += f" WHERE {where_clause}"
        return SqlReadCommand(
            engine="sqlserver",
            sql=sql,
            parameters=parameters.build(),
            purpose=SqlReadCommandPurpose.COUNT,
        )

    def compile_relation_batch(
        self,
        *,
        catalog: GraphqlCatalog,
        selection: SqlRelationBatchSelection,
    ) -> SqlReadCommand:
        source_object = self._resolve_object(catalog, selection.source_object_id)
        relation = next(
            (candidate for candidate in source_object.relations if candidate.name == selection.relation_name),
            None,
        )
        if relation is None:
            raise ValueError(
                f"Unknown relation {selection.relation_name} for {selection.source_object_id}."
            )
        target_object = self._resolve_object(catalog, relation.target)
        parameters = _SqlParameterBuilder()
        select_list = self._build_select_list(target_object, selection.projected_fields)
        where_clause = self._compile_relation_batch_predicate(
            source_object=source_object,
            target_object=target_object,
            relation=relation,
            parent_keys=selection.parent_keys,
            parameters=parameters,
        )
        return SqlReadCommand(
            engine="sqlserver",
            sql=f"SELECT {select_list} FROM {self._table_ref(target_object)} WHERE {where_clause}",
            parameters=parameters.build(),
            purpose=SqlReadCommandPurpose.RELATION_BATCH,
        )

    def _resolve_object(self, catalog: GraphqlCatalog, object_id: str) -> GraphqlPublishedObject:
        object_ = next((candidate for candidate in catalog.objects if candidate.id == object_id), None)
        if object_ is None:
            raise ValueError(f"Unknown catalog object {object_id}.")
        return object_

    def _table_ref(self, object_: GraphqlPublishedObject) -> str:
        return f"[{object_.source.schema_name}].[{object_.source.object_name}]"

    def _build_select_list(
        self,
        object_: GraphqlPublishedObject,
        public_fields: tuple[str, ...],
    ) -> str:
        return ", ".join(
            f"[{field.column}] AS [{field.public_name}]"
            for field in (self._resolve_field_by_public_name(object_, public_name) for public_name in public_fields)
        )

    def _compile_key_predicate(
        self,
        *,
        object_: GraphqlPublishedObject,
        public_key_values: dict[str, object],
        parameters: _SqlParameterBuilder,
    ) -> str:
        clauses: list[str] = []
        for key_column in object_.identity.fields:
            field = self._resolve_field_by_column(object_, key_column)
            if field.public_name not in public_key_values:
                raise ValueError(f"Missing key component {field.public_name}.")
            parameter_name = parameters.add(public_key_values[field.public_name], type_=field.type)
            clauses.append(f"[{field.column}] = @{parameter_name}")
        return " AND ".join(clauses)

    def _compile_filter(
        self,
        *,
        object_: GraphqlPublishedObject,
        filter_: SqlFilterNode | None,
        parameters: _SqlParameterBuilder,
    ) -> str | None:
        if filter_ is None:
            return None
        if isinstance(filter_, SqlFilterCondition):
            return self._compile_filter_condition(object_, filter_, parameters)
        if isinstance(filter_, SqlFilterGroup):
            if not filter_.nodes:
                return None
            if filter_.kind is SqlFilterGroupKind.NOT:
                child = self._compile_filter(
                    object_=object_,
                    filter_=filter_.nodes[0],
                    parameters=parameters,
                )
                return None if child is None else f"NOT ({child})"
            compiled_children = [
                compiled
                for compiled in (
                    self._compile_filter(object_=object_, filter_=node, parameters=parameters)
                    for node in filter_.nodes
                )
                if compiled is not None
            ]
            if not compiled_children:
                return None
            joiner = " AND " if filter_.kind is SqlFilterGroupKind.AND else " OR "
            return f"({joiner.join(compiled_children)})"
        raise ValueError(f"Unsupported filter node {type(filter_).__name__}.")

    def _compile_filter_condition(
        self,
        object_: GraphqlPublishedObject,
        condition: SqlFilterCondition,
        parameters: _SqlParameterBuilder,
    ) -> str:
        field = self._resolve_field_by_public_name(object_, condition.field)
        column_ref = f"[{field.column}]"
        if condition.operator in {SqlFilterOperator.EQ, SqlFilterOperator.NE} and condition.value is None:
            raise ValueError(f"Use isNull instead of eq/ne with null for {condition.field}.")

        if condition.operator is SqlFilterOperator.EQ:
            return f"{column_ref} = @{parameters.add(condition.value, type_=field.type)}"
        if condition.operator is SqlFilterOperator.NE:
            return f"{column_ref} <> @{parameters.add(condition.value, type_=field.type)}"
        if condition.operator is SqlFilterOperator.IN_LIST:
            values = tuple(condition.value) if isinstance(condition.value, (list, tuple)) else ()
            if not values:
                return "1 = 0"
            parameter_refs = ", ".join(f"@{parameters.add(value, type_=field.type)}" for value in values)
            return f"{column_ref} IN ({parameter_refs})"
        if condition.operator is SqlFilterOperator.LT:
            return f"{column_ref} < @{parameters.add(condition.value, type_=field.type)}"
        if condition.operator is SqlFilterOperator.LTE:
            return f"{column_ref} <= @{parameters.add(condition.value, type_=field.type)}"
        if condition.operator is SqlFilterOperator.GT:
            return f"{column_ref} > @{parameters.add(condition.value, type_=field.type)}"
        if condition.operator is SqlFilterOperator.GTE:
            return f"{column_ref} >= @{parameters.add(condition.value, type_=field.type)}"
        if condition.operator is SqlFilterOperator.IS_NULL:
            if not isinstance(condition.value, bool):
                raise ValueError(f"isNull expects a boolean for {condition.field}.")
            return f"{column_ref} IS NULL" if condition.value else f"{column_ref} IS NOT NULL"
        if condition.operator is SqlFilterOperator.CONTAINS:
            return f"{column_ref} LIKE '%' + @{parameters.add(condition.value, type_=field.type)} + '%'"
        if condition.operator is SqlFilterOperator.STARTS_WITH:
            return f"{column_ref} LIKE @{parameters.add(condition.value, type_=field.type)} + '%'"
        if condition.operator is SqlFilterOperator.ENDS_WITH:
            return f"{column_ref} LIKE '%' + @{parameters.add(condition.value, type_=field.type)}"
        raise ValueError(f"Unsupported filter operator {condition.operator}.")

    def _build_order_by(
        self,
        object_: GraphqlPublishedObject,
        clauses: tuple[SqlOrderByClause, ...],
    ) -> str:
        parts: list[str] = []
        for clause in clauses:
            field = self._resolve_field_by_public_name(object_, clause.field)
            direction = "ASC" if clause.direction is SqlSortDirection.ASC else "DESC"
            parts.append(f"[{field.column}] {direction}")
        return ", ".join(parts)

    def _compile_relation_batch_predicate(
        self,
        *,
        source_object: GraphqlPublishedObject,
        target_object: GraphqlPublishedObject,
        relation: GraphqlCatalogRelation,
        parent_keys: tuple[dict[str, object], ...],
        parameters: _SqlParameterBuilder,
    ) -> str:
        if len(relation.target_fields) == 1:
            if not parent_keys:
                return "1 = 0"
            source_field = self._resolve_field_by_column(source_object, relation.source_fields[0])
            target_field = self._resolve_field_by_column(target_object, relation.target_fields[0])
            parameter_refs: list[str] = []
            for parent_key in parent_keys:
                if source_field.public_name not in parent_key:
                    raise ValueError(
                        f"Missing parent key component {source_field.public_name} for relation {relation.name}."
                    )
                parameter_refs.append(
                    f"@{parameters.add(parent_key[source_field.public_name], type_=target_field.type)}"
                )
            return f"[{target_field.column}] IN ({', '.join(parameter_refs)})"

        if not parent_keys:
            return "1 = 0"
        disjunctions: list[str] = []
        for parent_key in parent_keys:
            conjunctions: list[str] = []
            for index, target_field_name in enumerate(relation.target_fields):
                source_field = self._resolve_field_by_column(source_object, relation.source_fields[index])
                target_field = self._resolve_field_by_column(target_object, target_field_name)
                if source_field.public_name not in parent_key:
                    raise ValueError(
                        f"Missing parent key component {source_field.public_name} for relation {relation.name}."
                    )
                parameter_name = parameters.add(parent_key[source_field.public_name], type_=target_field.type)
                conjunctions.append(f"[{target_field.column}] = @{parameter_name}")
            disjunctions.append(f"({' AND '.join(conjunctions)})")
        return " OR ".join(disjunctions)

    def _resolve_field_by_public_name(
        self,
        object_: GraphqlPublishedObject,
        public_name: str,
    ) -> GraphqlCatalogField:
        field = next((candidate for candidate in object_.fields if candidate.public_name == public_name), None)
        if field is None:
            raise ValueError(f"Unknown public field {public_name} for {object_.id}.")
        return field

    def _resolve_field_by_column(
        self,
        object_: GraphqlPublishedObject,
        column: str,
    ) -> GraphqlCatalogField:
        field = next((candidate for candidate in object_.fields if candidate.column == column), None)
        if field is None:
            raise ValueError(f"Unknown source column {column} for {object_.id}.")
        return field


class SqlCatalogReadDispatcher:
    def __init__(self, *, compiler: SqlServerReadCompiler, executor: ReadExecutor) -> None:
        self.compiler = compiler
        self.executor = executor

    async def read_item(
        self,
        *,
        catalog: GraphqlCatalog,
        selection: SqlItemSelection,
        context: ReadExecutionContext,
    ) -> RowSet:
        command = self.compiler.compile_item(catalog=catalog, selection=selection)
        return await self.executor.execute(command, context)

    async def read_collection(
        self,
        *,
        catalog: GraphqlCatalog,
        selection: SqlCollectionSelection,
        context: ReadExecutionContext,
    ) -> RowSet:
        command = self.compiler.compile_collection(catalog=catalog, selection=selection)
        return await self.executor.execute(command, context)

    async def read_count(
        self,
        *,
        catalog: GraphqlCatalog,
        selection: SqlCountSelection,
        context: ReadExecutionContext,
    ) -> RowSet:
        command = self.compiler.compile_count(catalog=catalog, selection=selection)
        return await self.executor.execute(command, context)

    async def read_relation_batch(
        self,
        *,
        catalog: GraphqlCatalog,
        selection: SqlRelationBatchSelection,
        context: ReadExecutionContext,
    ) -> RowSet:
        command = self.compiler.compile_relation_batch(catalog=catalog, selection=selection)
        return await self.executor.execute(command, context)


class _SqlParameterBuilder:
    def __init__(self) -> None:
        self._parameters: list[SqlParameter] = []

    def add(self, value: object, *, type_: str | None = None) -> str:
        name = f"p{len(self._parameters)}"
        self._parameters.append(SqlParameter(name=name, value=value, type=type_))
        return name

    def build(self) -> tuple[SqlParameter, ...]:
        return tuple(self._parameters)