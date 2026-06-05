import type {
  GraphqlCatalog,
  GraphqlCatalogField,
  GraphqlCatalogRelation,
  GraphqlPublishedObject,
} from '../catalog/graphql_catalog_builder';
import {
  ReadExecutionContext,
  type ReadExecutor,
  RowSet,
  SqlCollectionSelection,
  SqlCountSelection,
  SqlFilterCondition,
  SqlFilterGroup,
  SqlFilterGroupKind,
  type SqlFilterNode,
  SqlFilterOperator,
  SqlItemSelection,
  SqlOrderByClause,
  SqlPage,
  SqlParameter,
  SqlReadCommand,
  SqlReadCommandPurpose,
  SqlRelationBatchSelection,
  SqlSortDirection,
} from './sql_read_contract';

export class SqlServerReadCompiler {
  compileItem(options: { catalog: GraphqlCatalog; selection: SqlItemSelection }): SqlReadCommand {
    const object = this.resolveObject(options.catalog, options.selection.objectId);
    const parameters = new SqlParameterBuilder();
    const selectList = this.buildSelectList(object, options.selection.projectedFields);
    const whereClause = this.compileKeyPredicate({
      object,
      publicKeyValues: options.selection.key,
      parameters,
    });

    return new SqlReadCommand({
      engine: 'sqlserver',
      sql: `SELECT TOP (1) ${selectList} FROM ${this.tableRef(object)} WHERE ${whereClause}`,
      parameters: parameters.build(),
      purpose: SqlReadCommandPurpose.Item,
    });
  }

  compileCollection(options: {
    catalog: GraphqlCatalog;
    selection: SqlCollectionSelection;
  }): SqlReadCommand {
    const object = this.resolveObject(options.catalog, options.selection.objectId);
    const parameters = new SqlParameterBuilder();
    let sql = `SELECT ${this.buildSelectList(object, options.selection.projectedFields)} FROM ${this.tableRef(object)}`;

    const whereClause = this.compileFilter({
      object,
      filter: options.selection.filter,
      parameters,
    });
    if (whereClause) {
      sql += ` WHERE ${whereClause}`;
    }

    if (options.selection.orderBy.length > 0) {
      sql += ` ORDER BY ${this.buildOrderBy(object, options.selection.orderBy)}`;
    }

    if (options.selection.page instanceof SqlPage) {
      const offsetName = parameters.add(options.selection.page.offset, 'Int');
      const limitName = parameters.add(options.selection.page.limit, 'Int');
      sql += ` OFFSET @${offsetName} ROWS FETCH NEXT @${limitName} ROWS ONLY`;
    }

    return new SqlReadCommand({
      engine: 'sqlserver',
      sql,
      parameters: parameters.build(),
      purpose: SqlReadCommandPurpose.Collection,
    });
  }

  compileCount(options: { catalog: GraphqlCatalog; selection: SqlCountSelection }): SqlReadCommand {
    const object = this.resolveObject(options.catalog, options.selection.objectId);
    const parameters = new SqlParameterBuilder();
    let sql = `SELECT COUNT_BIG(1) AS [totalCount] FROM ${this.tableRef(object)}`;
    const whereClause = this.compileFilter({
      object,
      filter: options.selection.filter,
      parameters,
    });
    if (whereClause) {
      sql += ` WHERE ${whereClause}`;
    }

    return new SqlReadCommand({
      engine: 'sqlserver',
      sql,
      parameters: parameters.build(),
      purpose: SqlReadCommandPurpose.Count,
    });
  }

  compileRelationBatch(options: {
    catalog: GraphqlCatalog;
    selection: SqlRelationBatchSelection;
  }): SqlReadCommand {
    const sourceObject = this.resolveObject(options.catalog, options.selection.sourceObjectId);
    const relation = sourceObject.relations.find((candidate) => candidate.name === options.selection.relationName);
    if (!relation) {
      throw new Error(`Unknown relation ${options.selection.relationName} for ${options.selection.sourceObjectId}.`);
    }
    const targetObject = this.resolveObject(options.catalog, relation.target);
    const parameters = new SqlParameterBuilder();
    const selectList = this.buildSelectList(targetObject, options.selection.projectedFields);
    const whereClause = this.compileRelationBatchPredicate({
      sourceObject,
      targetObject,
      relation,
      parentKeys: options.selection.parentKeys,
      parameters,
    });

    return new SqlReadCommand({
      engine: 'sqlserver',
      sql: `SELECT ${selectList} FROM ${this.tableRef(targetObject)} WHERE ${whereClause}`,
      parameters: parameters.build(),
      purpose: SqlReadCommandPurpose.RelationBatch,
    });
  }

  private resolveObject(catalog: GraphqlCatalog, objectId: string): GraphqlPublishedObject {
    const object = catalog.objects.find((candidate) => candidate.id === objectId);
    if (!object) {
      throw new Error(`Unknown catalog object ${objectId}.`);
    }
    return object;
  }

  private tableRef(object: GraphqlPublishedObject): string {
    return `[${object.source.schemaName}].[${object.source.objectName}]`;
  }

  private buildSelectList(object: GraphqlPublishedObject, publicFields: readonly string[]): string {
    return publicFields
      .map((publicField) => {
        const field = this.resolveFieldByPublicName(object, publicField);
        return `[${field.column}] AS [${field.publicName}]`;
      })
      .join(', ');
  }

  private compileKeyPredicate(options: {
    object: GraphqlPublishedObject;
    publicKeyValues: Readonly<Record<string, unknown>>;
    parameters: SqlParameterBuilder;
  }): string {
    const clauses: string[] = [];
    for (const keyColumn of options.object.identity.fields) {
      const field = this.resolveFieldByColumn(options.object, keyColumn);
      if (!(field.publicName in options.publicKeyValues)) {
        throw new Error(`Missing key component ${field.publicName}.`);
      }
      const parameterName = options.parameters.add(options.publicKeyValues[field.publicName], field.type);
      clauses.push(`[${field.column}] = @${parameterName}`);
    }
    return clauses.join(' AND ');
  }

  private compileFilter(options: {
    object: GraphqlPublishedObject;
    filter: SqlFilterNode | undefined;
    parameters: SqlParameterBuilder;
  }): string | undefined {
    if (!options.filter) {
      return undefined;
    }
    if (options.filter instanceof SqlFilterCondition) {
      return this.compileFilterCondition(options.object, options.filter, options.parameters);
    }
    if (options.filter instanceof SqlFilterGroup) {
      if (options.filter.nodes.length === 0) {
        return undefined;
      }
      if (options.filter.kind === SqlFilterGroupKind.Not) {
        const child = this.compileFilter({
          object: options.object,
          filter: options.filter.nodes[0],
          parameters: options.parameters,
        });
        return child ? `NOT (${child})` : undefined;
      }

      const compiledChildren = options.filter.nodes
        .map((node) => this.compileFilter({ object: options.object, filter: node, parameters: options.parameters }))
        .filter((node): node is string => typeof node === 'string' && node.length > 0);
      if (compiledChildren.length === 0) {
        return undefined;
      }
      const joiner = options.filter.kind === SqlFilterGroupKind.And ? ' AND ' : ' OR ';
      return `(${compiledChildren.join(joiner)})`;
    }

    throw new Error(`Unsupported filter node ${(options.filter as object).constructor?.name ?? typeof options.filter}.`);
  }

  private compileFilterCondition(
    object: GraphqlPublishedObject,
    condition: SqlFilterCondition,
    parameters: SqlParameterBuilder,
  ): string {
    const field = this.resolveFieldByPublicName(object, condition.field);
    const columnRef = `[${field.column}]`;

    if ((condition.operator === SqlFilterOperator.Eq || condition.operator === SqlFilterOperator.Ne) && condition.value == null) {
      throw new Error(`Use isNull instead of eq/ne with null for ${condition.field}.`);
    }

    switch (condition.operator) {
      case SqlFilterOperator.Eq:
        return `${columnRef} = @${parameters.add(condition.value, field.type)}`;
      case SqlFilterOperator.Ne:
        return `${columnRef} <> @${parameters.add(condition.value, field.type)}`;
      case SqlFilterOperator.InList: {
        const values = Array.isArray(condition.value) ? condition.value : [];
        if (values.length === 0) {
          return '1 = 0';
        }
        const parameterRefs = values.map((value) => `@${parameters.add(value, field.type)}`).join(', ');
        return `${columnRef} IN (${parameterRefs})`;
      }
      case SqlFilterOperator.Lt:
        return `${columnRef} < @${parameters.add(condition.value, field.type)}`;
      case SqlFilterOperator.Lte:
        return `${columnRef} <= @${parameters.add(condition.value, field.type)}`;
      case SqlFilterOperator.Gt:
        return `${columnRef} > @${parameters.add(condition.value, field.type)}`;
      case SqlFilterOperator.Gte:
        return `${columnRef} >= @${parameters.add(condition.value, field.type)}`;
      case SqlFilterOperator.IsNull:
        if (typeof condition.value !== 'boolean') {
          throw new Error(`isNull expects a boolean for ${condition.field}.`);
        }
        return condition.value ? `${columnRef} IS NULL` : `${columnRef} IS NOT NULL`;
      case SqlFilterOperator.Contains:
        return `${columnRef} LIKE '%' + @${parameters.add(condition.value, field.type)} + '%'`;
      case SqlFilterOperator.StartsWith:
        return `${columnRef} LIKE @${parameters.add(condition.value, field.type)} + '%'`;
      case SqlFilterOperator.EndsWith:
        return `${columnRef} LIKE '%' + @${parameters.add(condition.value, field.type)}`;
    }
  }

  private buildOrderBy(object: GraphqlPublishedObject, clauses: readonly SqlOrderByClause[]): string {
    return clauses
      .map((clause) => {
        const field = this.resolveFieldByPublicName(object, clause.field);
        const direction = clause.direction === SqlSortDirection.Asc ? 'ASC' : 'DESC';
        return `[${field.column}] ${direction}`;
      })
      .join(', ');
  }

  private compileRelationBatchPredicate(options: {
    sourceObject: GraphqlPublishedObject;
    targetObject: GraphqlPublishedObject;
    relation: GraphqlCatalogRelation;
    parentKeys: readonly Readonly<Record<string, unknown>>[];
    parameters: SqlParameterBuilder;
  }): string {
    if (options.relation.targetFields.length === 1) {
      const sourceField = this.resolveFieldByColumn(options.sourceObject, options.relation.sourceFields[0]!);
      const targetField = this.resolveFieldByColumn(options.targetObject, options.relation.targetFields[0]!);
      const parameterRefs = options.parentKeys.map((parentKey) => {
        if (!(sourceField.publicName in parentKey)) {
          throw new Error(`Missing parent key component ${sourceField.publicName} for relation ${options.relation.name}.`);
        }
        return `@${options.parameters.add(parentKey[sourceField.publicName], targetField.type)}`;
      });
      return `[${targetField.column}] IN (${parameterRefs.join(', ')})`;
    }

    const disjunctions: string[] = [];
    for (const parentKey of options.parentKeys) {
      const conjunctions: string[] = [];
      for (let index = 0; index < options.relation.targetFields.length; index += 1) {
        const sourceField = this.resolveFieldByColumn(options.sourceObject, options.relation.sourceFields[index]!);
        const targetField = this.resolveFieldByColumn(options.targetObject, options.relation.targetFields[index]!);
        if (!(sourceField.publicName in parentKey)) {
          throw new Error(`Missing parent key component ${sourceField.publicName} for relation ${options.relation.name}.`);
        }
        const parameterName = options.parameters.add(parentKey[sourceField.publicName], targetField.type);
        conjunctions.push(`[${targetField.column}] = @${parameterName}`);
      }
      disjunctions.push(`(${conjunctions.join(' AND ')})`);
    }
    return disjunctions.join(' OR ');
  }

  private resolveFieldByPublicName(object: GraphqlPublishedObject, publicName: string): GraphqlCatalogField {
    const field = object.fields.find((candidate) => candidate.publicName === publicName);
    if (!field) {
      throw new Error(`Unknown public field ${publicName} for ${object.id}.`);
    }
    return field;
  }

  private resolveFieldByColumn(object: GraphqlPublishedObject, column: string): GraphqlCatalogField {
    const field = object.fields.find((candidate) => candidate.column === column);
    if (!field) {
      throw new Error(`Unknown source column ${column} for ${object.id}.`);
    }
    return field;
  }
}

export class SqlCatalogReadDispatcher {
  readonly compiler: SqlServerReadCompiler;
  readonly executor: ReadExecutor;

  constructor(options: { compiler: SqlServerReadCompiler; executor: ReadExecutor }) {
    this.compiler = options.compiler;
    this.executor = options.executor;
  }

  readItem(options: {
    catalog: GraphqlCatalog;
    selection: SqlItemSelection;
    context: ReadExecutionContext;
  }): Promise<RowSet> {
    const command = this.compiler.compileItem({ catalog: options.catalog, selection: options.selection });
    return this.executor.execute(command, options.context);
  }

  readCollection(options: {
    catalog: GraphqlCatalog;
    selection: SqlCollectionSelection;
    context: ReadExecutionContext;
  }): Promise<RowSet> {
    const command = this.compiler.compileCollection({ catalog: options.catalog, selection: options.selection });
    return this.executor.execute(command, options.context);
  }

  readCount(options: {
    catalog: GraphqlCatalog;
    selection: SqlCountSelection;
    context: ReadExecutionContext;
  }): Promise<RowSet> {
    const command = this.compiler.compileCount({ catalog: options.catalog, selection: options.selection });
    return this.executor.execute(command, options.context);
  }

  readRelationBatch(options: {
    catalog: GraphqlCatalog;
    selection: SqlRelationBatchSelection;
    context: ReadExecutionContext;
  }): Promise<RowSet> {
    const command = this.compiler.compileRelationBatch({ catalog: options.catalog, selection: options.selection });
    return this.executor.execute(command, options.context);
  }
}

class SqlParameterBuilder {
  private readonly parameters: SqlParameter[] = [];

  add(value: unknown, type?: string): string {
    const name = `p${this.parameters.length}`;
    this.parameters.push(new SqlParameter({ name, type, value }));
    return name;
  }

  build(): readonly SqlParameter[] {
    return Object.freeze([...this.parameters]);
  }
}