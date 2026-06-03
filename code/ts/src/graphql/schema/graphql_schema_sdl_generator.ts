import {
  GraphqlCatalogFieldVisibility,
  GraphqlCatalogRelationCardinality,
  type GraphqlCatalog,
  type GraphqlCatalogField,
  type GraphqlPublishedObject,
} from '../catalog/graphql_catalog_builder';

export class GraphqlSchemaSdlGenerator {
  generate(catalog: GraphqlCatalog): string {
    const objects = [...catalog.objects].sort((left, right) => left.id.localeCompare(right.id));
    const objectById = new Map(objects.map((object) => [object.id, object]));
    const blocks: string[] = [];

    const customScalars = this.collectCustomScalars(objects);
    if (customScalars.length > 0) {
      blocks.push(customScalars.map((scalar) => `scalar ${scalar}`).join('\n'));
    }

    blocks.push(this.buildQueryType(objects));

    for (const object of objects) {
      blocks.push(this.buildObjectType(object, objectById));
      blocks.push(this.buildListEnvelope(object));
      if (object.capabilities.item && object.graphql.itemField) {
        blocks.push(this.buildKeyInput(object));
      }
      blocks.push(this.buildFilterInput(object));
      blocks.push(this.buildOrderByInput(object));
      blocks.push(this.buildOrderFieldEnum(object));
    }

    for (const family of this.collectUsedFilterFamilies(objects)) {
      blocks.push(this.buildScalarFilterInput(family));
    }

    blocks.push(`enum SortDirection {
  ASC
  DESC
}`);
    blocks.push(`input OffsetPageInput {
  limit: Int
  offset: Int
}`);

    return blocks.join('\n\n');
  }

  private collectCustomScalars(objects: readonly GraphqlPublishedObject[]): string[] {
    const scalars = new Set<string>();

    for (const object of objects) {
      for (const field of object.fields) {
        if (this.isCustomScalar(field.type)) {
          scalars.add(field.type);
        }
      }
    }

    return [...scalars].sort((left, right) => left.localeCompare(right));
  }

  private buildQueryType(objects: readonly GraphqlPublishedObject[]): string {
    const lines = ['type Query {'];

    for (const object of objects) {
      if (object.capabilities.item && object.graphql.itemField) {
        lines.push(`  ${object.graphql.itemField}(key: ${object.graphql.typeName}KeyInput!): ${object.graphql.typeName}`);
      }
      if (object.capabilities.collection) {
        lines.push(`  ${object.graphql.collectionField}(`);
        lines.push(`    filter: ${object.graphql.typeName}FilterInput`);
        lines.push(`    orderBy: [${object.graphql.typeName}OrderByInput!]`);
        lines.push('    page: OffsetPageInput');
        lines.push(`  ): ${object.graphql.typeName}List!`);
      }
    }

    lines.push('}');
    return lines.join('\n');
  }

  private buildObjectType(
    object: GraphqlPublishedObject,
    objectById: ReadonlyMap<string, GraphqlPublishedObject>,
  ): string {
    const lines = [`type ${object.graphql.typeName} {`];

    for (const field of object.fields) {
      if (field.visibility !== GraphqlCatalogFieldVisibility.Public) {
        continue;
      }
      lines.push(`  ${field.publicName}: ${this.graphqlFieldType(field.type, field.nullable)}`);
    }

    for (const relation of object.relations) {
      const target = objectById.get(relation.target);
      if (!target) {
        continue;
      }
      const relationType =
        relation.cardinality === GraphqlCatalogRelationCardinality.Many
          ? `[${target.graphql.typeName}!]!`
          : target.graphql.typeName;
      lines.push(`  ${relation.name}: ${relationType}`);
    }

    lines.push('}');
    return lines.join('\n');
  }

  private buildListEnvelope(object: GraphqlPublishedObject): string {
    return `type ${object.graphql.typeName}List {
  items: [${object.graphql.typeName}!]!
  totalCount: Int!
}`;
  }

  private buildKeyInput(object: GraphqlPublishedObject): string {
    const fieldByColumn = new Map(object.fields.map((field) => [field.column, field]));
    const lines = [`input ${object.graphql.typeName}KeyInput {`];

    for (const column of object.identity.fields) {
      const field = fieldByColumn.get(column);
      if (!field) {
        continue;
      }
      lines.push(`  ${field.publicName}: ${field.type}!`);
    }

    lines.push('}');
    return lines.join('\n');
  }

  private buildFilterInput(object: GraphqlPublishedObject): string {
    const lines = [`input ${object.graphql.typeName}FilterInput {`];
    lines.push(`  and: [${object.graphql.typeName}FilterInput!]`);
    lines.push(`  or: [${object.graphql.typeName}FilterInput!]`);
    lines.push(`  not: ${object.graphql.typeName}FilterInput`);

    for (const field of object.fields) {
      if (
        field.visibility !== GraphqlCatalogFieldVisibility.Public ||
        !field.filterable ||
        field.type === 'Json'
      ) {
        continue;
      }
      lines.push(`  ${field.publicName}: ${field.type}FilterInput`);
    }

    lines.push('}');
    return lines.join('\n');
  }

  private buildOrderByInput(object: GraphqlPublishedObject): string {
    return `input ${object.graphql.typeName}OrderByInput {
  field: ${object.graphql.typeName}OrderField!
  direction: SortDirection!
}`;
  }

  private buildOrderFieldEnum(object: GraphqlPublishedObject): string {
    const lines = [`enum ${object.graphql.typeName}OrderField {`];

    for (const field of object.fields) {
      if (field.visibility !== GraphqlCatalogFieldVisibility.Public || !field.sortable) {
        continue;
      }
      lines.push(`  ${this.enumValueForFieldName(field.publicName)}`);
    }

    lines.push('}');
    return lines.join('\n');
  }

  private collectUsedFilterFamilies(objects: readonly GraphqlPublishedObject[]): string[] {
    const families = new Set<string>();

    for (const object of objects) {
      for (const field of object.fields) {
        if (
          field.visibility === GraphqlCatalogFieldVisibility.Public &&
          field.filterable &&
          field.type !== 'Json'
        ) {
          families.add(field.type);
        }
      }
    }

    return [...families].sort((left, right) => left.localeCompare(right));
  }

  private buildScalarFilterInput(scalar: string): string {
    switch (scalar) {
      case 'String':
        return `input StringFilterInput {
  eq: String
  ne: String
  in: [String!]
  contains: String
  startsWith: String
  endsWith: String
  isNull: Boolean
}`;
      case 'Boolean':
        return `input BooleanFilterInput {
  eq: Boolean
  ne: Boolean
  isNull: Boolean
}`;
      case 'Uuid':
        return `input UuidFilterInput {
  eq: Uuid
  ne: Uuid
  in: [Uuid!]
  isNull: Boolean
}`;
      case 'Int':
      case 'Long':
      case 'Float':
      case 'Decimal':
      case 'Date':
      case 'DateTime':
        return `input ${scalar}FilterInput {
  eq: ${scalar}
  ne: ${scalar}
  in: [${scalar}!]
  lt: ${scalar}
  lte: ${scalar}
  gt: ${scalar}
  gte: ${scalar}
  isNull: Boolean
}`;
      case 'Json':
        throw new Error('Json fields do not expose scalar filter operators in v1.');
      default:
        throw new Error(`Unsupported scalar family ${scalar} for filter input generation.`);
    }
  }

  private isCustomScalar(scalar: string): boolean {
    return ['Long', 'Decimal', 'Date', 'DateTime', 'Uuid', 'Json'].includes(scalar);
  }

  private graphqlFieldType(scalar: string, nullable: boolean): string {
    return nullable ? scalar : `${scalar}!`;
  }

  private enumValueForFieldName(publicName: string): string {
    const words: string[] = [];
    const segmentPattern = /[A-Za-z0-9]+/g;
    const wordPattern = /[A-Z]+(?:\d+)?(?=[A-Z][a-z]|$)|[A-Z]?[a-z]+\d*|\d+/g;
    const segments = publicName.match(segmentPattern) ?? [];

    for (const segment of segments) {
      const matches = segment.match(wordPattern) ?? [];
      for (const match of matches) {
        if (match) {
          words.push(match.toUpperCase());
        }
      }
    }

    return words.join('_');
  }
}