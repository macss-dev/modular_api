"""GraphQL SDL generator for Stage 4 schema generation."""

from __future__ import annotations

import re

from modular_api.graphql.catalog import (
    GraphqlCatalog,
    GraphqlCatalogField,
    GraphqlCatalogFieldVisibility,
    GraphqlCatalogRelationCardinality,
    GraphqlPublishedObject,
)


class GraphqlSchemaSdlGenerator:
    _segment_pattern = re.compile(r"[A-Za-z0-9]+")
    _word_pattern = re.compile(r"[A-Z]+(?:\d+)?(?=[A-Z][a-z]|$)|[A-Z]?[a-z]+\d*|\d+")

    def generate(self, catalog: GraphqlCatalog) -> str:
        objects = tuple(sorted(catalog.objects, key=lambda object_: object_.id))
        object_by_id = {object_.id: object_ for object_ in objects}
        blocks: list[str] = []

        custom_scalars = self._collect_custom_scalars(objects)
        if custom_scalars:
            blocks.append("\n".join(f"scalar {scalar}" for scalar in custom_scalars))

        blocks.append(self._build_query_type(objects))

        for object_ in objects:
            blocks.append(self._build_object_type(object_, object_by_id))
            blocks.append(self._build_list_envelope(object_))
            if object_.capabilities.item and object_.graphql.item_field is not None:
                blocks.append(self._build_key_input(object_))
            blocks.append(self._build_filter_input(object_))
            blocks.append(self._build_order_by_input(object_))
            blocks.append(self._build_order_field_enum(object_))

        for family in self._collect_used_filter_families(objects):
            blocks.append(self._build_scalar_filter_input(family))

        blocks.append(
            """enum SortDirection {
  ASC
  DESC
}"""
        )
        blocks.append(
            """input OffsetPageInput {
  limit: Int
  offset: Int
}"""
        )
        return "\n\n".join(blocks)

    def _collect_custom_scalars(self, objects: tuple[GraphqlPublishedObject, ...]) -> list[str]:
        scalars = {
            field.type
            for object_ in objects
            for field in object_.fields
            if self._is_custom_scalar(field.type)
        }
        return sorted(scalars)

    def _build_query_type(self, objects: tuple[GraphqlPublishedObject, ...]) -> str:
        lines = ["type Query {"]
        for object_ in objects:
            if object_.capabilities.item and object_.graphql.item_field is not None:
                lines.append(
                    f"  {object_.graphql.item_field}(key: {object_.graphql.type_name}KeyInput!): {object_.graphql.type_name}"
                )
            if object_.capabilities.collection:
                lines.extend(
                    [
                        f"  {object_.graphql.collection_field}(",
                        f"    filter: {object_.graphql.type_name}FilterInput",
                        f"    orderBy: [{object_.graphql.type_name}OrderByInput!]",
                        "    page: OffsetPageInput",
                        f"  ): {object_.graphql.type_name}List!",
                    ]
                )
        lines.append("}")
        return "\n".join(lines)

    def _build_object_type(
        self,
        object_: GraphqlPublishedObject,
        object_by_id: dict[str, GraphqlPublishedObject],
    ) -> str:
        lines = [f"type {object_.graphql.type_name} {{"]
        for field in object_.fields:
            if field.visibility is not GraphqlCatalogFieldVisibility.PUBLIC:
                continue
            lines.append(f"  {field.public_name}: {self._graphql_field_type(field.type, field.nullable)}")
        for relation in object_.relations:
            target = object_by_id.get(relation.target)
            if target is None:
                continue
            relation_type = (
                f"[{target.graphql.type_name}!]!"
                if relation.cardinality is GraphqlCatalogRelationCardinality.MANY
                else target.graphql.type_name
            )
            lines.append(f"  {relation.name}: {relation_type}")
        lines.append("}")
        return "\n".join(lines)

    def _build_list_envelope(self, object_: GraphqlPublishedObject) -> str:
        return f"""type {object_.graphql.type_name}List {{
  items: [{object_.graphql.type_name}!]!
  totalCount: Int!
}}"""

    def _build_key_input(self, object_: GraphqlPublishedObject) -> str:
        field_by_column = {field.column: field for field in object_.fields}
        lines = [f"input {object_.graphql.type_name}KeyInput {{"]
        for column in object_.identity.fields:
            field = field_by_column.get(column)
            if field is None:
                continue
            lines.append(f"  {field.public_name}: {field.type}!")
        lines.append("}")
        return "\n".join(lines)

    def _build_filter_input(self, object_: GraphqlPublishedObject) -> str:
        lines = [f"input {object_.graphql.type_name}FilterInput {{"]
        lines.append(f"  and: [{object_.graphql.type_name}FilterInput!]")
        lines.append(f"  or: [{object_.graphql.type_name}FilterInput!]")
        lines.append(f"  not: {object_.graphql.type_name}FilterInput")
        for field in object_.fields:
            if (
                field.visibility is not GraphqlCatalogFieldVisibility.PUBLIC
                or not field.filterable
                or field.type == "Json"
            ):
                continue
            lines.append(f"  {field.public_name}: {field.type}FilterInput")
        lines.append("}")
        return "\n".join(lines)

    def _build_order_by_input(self, object_: GraphqlPublishedObject) -> str:
        return f"""input {object_.graphql.type_name}OrderByInput {{
  field: {object_.graphql.type_name}OrderField!
  direction: SortDirection!
}}"""

    def _build_order_field_enum(self, object_: GraphqlPublishedObject) -> str:
        lines = [f"enum {object_.graphql.type_name}OrderField {{"]
        for field in object_.fields:
            if field.visibility is not GraphqlCatalogFieldVisibility.PUBLIC or not field.sortable:
                continue
            lines.append(f"  {self._enum_value_for_field_name(field.public_name)}")
        lines.append("}")
        return "\n".join(lines)

    def _collect_used_filter_families(self, objects: tuple[GraphqlPublishedObject, ...]) -> list[str]:
        families = {
            field.type
            for object_ in objects
            for field in object_.fields
            if field.visibility is GraphqlCatalogFieldVisibility.PUBLIC
            and field.filterable
            and field.type != "Json"
        }
        return sorted(families)

    def _build_scalar_filter_input(self, scalar: str) -> str:
        if scalar == "String":
            return """input StringFilterInput {
  eq: String
  ne: String
  in: [String!]
  contains: String
  startsWith: String
  endsWith: String
  isNull: Boolean
}"""
        if scalar == "Boolean":
            return """input BooleanFilterInput {
  eq: Boolean
  ne: Boolean
  isNull: Boolean
}"""
        if scalar == "Uuid":
            return """input UuidFilterInput {
  eq: Uuid
  ne: Uuid
  in: [Uuid!]
  isNull: Boolean
}"""
        if scalar in {"Int", "Long", "Float", "Decimal", "Date", "DateTime"}:
            return f"""input {scalar}FilterInput {{
  eq: {scalar}
  ne: {scalar}
  in: [{scalar}!]
  lt: {scalar}
  lte: {scalar}
  gt: {scalar}
  gte: {scalar}
  isNull: Boolean
}}"""
        if scalar == "Json":
            raise ValueError("Json fields do not expose scalar filter operators in v1.")
        raise ValueError(f"Unsupported scalar family {scalar} for filter input generation.")

    def _is_custom_scalar(self, scalar: str) -> bool:
        return scalar in {"Long", "Decimal", "Date", "DateTime", "Uuid", "Json"}

    def _graphql_field_type(self, scalar: str, nullable: bool) -> str:
        return scalar if nullable else f"{scalar}!"

    def _enum_value_for_field_name(self, public_name: str) -> str:
        words: list[str] = []
        for segment in self._segment_pattern.findall(public_name):
            for word in self._word_pattern.findall(segment):
                if word:
                    words.append(word.upper())
        return "_".join(words)