import {
  buildSchema,
  defaultFieldResolver,
  execute,
  GraphQLError,
  Kind,
  NoSchemaIntrospectionCustomRule,
  parse,
  specifiedRules,
  validate,
  type DocumentNode,
  type FieldNode,
  type FragmentDefinitionNode,
  type GraphQLFieldResolver,
  type GraphQLResolveInfo,
  type GraphQLSchema,
  type SelectionSetNode,
} from 'graphql';

import { HealthCheck, HealthCheckResult } from '../../core/health/health_check';
import type { HealthService } from '../../core/health/health_service';
import type { Plugin, PluginHost, PluginManifest, PluginRequestContext, PluginValidationResult } from '../../core/plugin';
import type {
  GraphqlCatalog,
  GraphqlCatalogField,
  GraphqlCatalogRelation,
  GraphqlPublishedObject,
} from '../catalog/graphql_catalog_builder';
import { GraphqlCatalogRelationCardinality } from '../catalog/graphql_catalog_builder';
import {
  ReadExecutionContext,
  type ReadExecutor,
  type RowSet,
  SqlCollectionSelection,
  SqlCountSelection,
  SqlFilterCondition,
  SqlFilterGroup,
  SqlFilterOperator,
  SqlItemSelection,
  SqlOrderByClause,
  SqlPage,
  SqlRelationBatchSelection,
  SqlSortDirection,
} from '../read/sql_read_contract';
import { SqlCatalogReadDispatcher, SqlServerReadCompiler } from '../read/sqlserver_read_compiler';
import {
  GraphqlOptions,
  GraphqlRequestEvent,
  GraphqlRequestPhase,
  graphqlDefaultReadExecutorCapabilityId,
} from './graphql_runtime_options';

type GraphqlRuntimeStatus = 'disabled' | 'ready';
type RuntimeFieldResolver = (
  source: unknown,
  args: Record<string, unknown>,
  context: GraphqlExecutionContext,
  info: GraphQLResolveInfo,
) => Promise<unknown> | unknown;

interface GraphqlReadyState {
  catalog: GraphqlCatalog;
  executor: ReadExecutor;
  sdl: string;
  schema: GraphQLSchema;
  dispatcher: SqlCatalogReadDispatcher;
  resolvers: ReadonlyMap<string, RuntimeFieldResolver>;
}

interface GraphqlRuntimeState {
  status: GraphqlRuntimeStatus;
  ready?: GraphqlReadyState;
}

interface GraphqlExecutionContext {
  request: PluginRequestContext;
  readyState: GraphqlReadyState;
  relationLoaders: Map<string, RelationBatchLoader>;
}

interface RelationParentKey {
  readonly cacheKey: string;
  readonly values: Readonly<Record<string, unknown>>;
}

interface RelationBatchRequest {
  readonly key: RelationParentKey;
  resolve(rows: readonly Readonly<Record<string, unknown>>[]): void;
  reject(error: unknown): void;
}

type GraphqlResponseBody = {
  data?: unknown;
  errors?: readonly Record<string, unknown>[];
};

const OFFICIAL_PLUGIN_HOST_RANGE = '>=0.1.0 <0.2.0';
const GRAPHQL_JSON_CONTENT_TYPE = 'application/json; charset=utf-8';
const GRAPHQL_TOTAL_COUNT_THUNK_KEY = Symbol('graphql.totalCountThunk');

export class GraphqlRuntimePlugin implements Plugin {
  readonly manifest: PluginManifest = {
    id: 'modular_api.graphql',
    displayName: 'GraphQL Plugin',
    version: '0.1.0',
    hostApiVersion: OFFICIAL_PLUGIN_HOST_RANGE,
  };

  private readonly state: GraphqlRuntimeState = { status: 'disabled' };

  constructor(
    private readonly options: GraphqlOptions | undefined,
    private readonly healthService: HealthService,
  ) {}

  setup(host: PluginHost): void {
    this.healthService.addHealthCheck(new GraphqlRuntimeHealthCheck(() => this.state.status));

    if (!this.options) {
      return;
    }

    host.registerRoute({
      id: 'graphql.endpoint',
      method: 'POST',
      path: '/graphql',
      visibility: 'transport',
      handler: async (context) => this.handleRequest(context),
    });
  }

  async validate(host: PluginHost): Promise<PluginValidationResult[]> {
    if (!this.options) {
      return [];
    }

    if (this.options.maxDepth < 1) {
      return [
        this.validationFailure('graphql.maxDepth', 'GraphQL maxDepth must be greater than or equal to 1.'),
      ];
    }

    if (this.options.maxComplexity < 1) {
      return [
        this.validationFailure(
          'graphql.maxComplexity',
          'GraphQL maxComplexity must be greater than or equal to 1.',
        ),
      ];
    }

    if (this.options.defaultLimit < 0) {
      return [
        this.validationFailure('graphql.defaultLimit', 'GraphQL defaultLimit must be non-negative.'),
      ];
    }

    if (this.options.maxLimit < 1) {
      return [this.validationFailure('graphql.maxLimit', 'GraphQL maxLimit must be greater than zero.')];
    }

    if (this.options.defaultLimit > this.options.maxLimit) {
      return [
        this.validationFailure('graphql.defaultLimit', 'GraphQL defaultLimit cannot exceed maxLimit.'),
      ];
    }

    const executor = this.resolveExecutor(host);
    if ('validationFailure' in executor) {
      return [executor.validationFailure];
    }

    try {
      const catalog = await this.options.catalogFactory();
      const sdl = this.options.sdlFactory(catalog);
      validateGeneratedSdl(sdl);

      const schema = buildSchema(sdl);
      const dispatcher = new SqlCatalogReadDispatcher({
        compiler: new SqlServerReadCompiler(),
        executor: executor.value,
      });

      this.state.status = 'ready';
      this.state.ready = {
        catalog,
        executor: executor.value,
        sdl,
        schema,
        dispatcher,
        resolvers: buildResolverRegistry({ catalog, dispatcher, options: this.options }),
      };

      return [];
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const resourceId = message.startsWith('GraphQL schema generation failed:') ? 'graphql.schema' : 'graphql.catalog';
      return [
        this.validationFailure(
          resourceId,
          resourceId === 'graphql.schema' ? message : `GraphQL catalog construction failed: ${message}`,
        ),
      ];
    }
  }

  async shutdown(): Promise<void> {
    this.state.status = 'disabled';
    const ownedExecutor = this.options?.executor;
    if (ownedExecutor) {
      await ownedExecutor.close();
    }
  }

  private resolveExecutor(
    host: PluginHost,
  ):
    | { value: ReadExecutor }
    | { validationFailure: PluginValidationResult } {
    if (!this.options) {
      return {
        validationFailure: this.validationFailure(
          graphqlDefaultReadExecutorCapabilityId,
          'GraphQL runtime is not configured.',
        ),
      };
    }

    if (this.options.executor) {
      return { value: this.options.executor };
    }

    const capabilityId = this.options.executionCapabilityId ?? graphqlDefaultReadExecutorCapabilityId;
    const capability = host.resolveCapability(capabilityId);
    if (!capability) {
      return {
        validationFailure: this.validationFailure(
          capabilityId,
          `Missing GraphQL read executor capability: ${capabilityId}`,
        ),
      };
    }
    if (!isReadExecutor(capability.value)) {
      return {
        validationFailure: this.validationFailure(
          capabilityId,
          `Capability ${capabilityId} does not expose a ReadExecutor.`,
        ),
      };
    }

    return { value: capability.value };
  }

  private validationFailure(resourceId: string, message: string): PluginValidationResult {
    return {
      code: 'PLUGIN_VALIDATION_FAILED',
      message,
      pluginId: this.manifest.id,
      resourceId,
    };
  }

  private async handleRequest(context: PluginRequestContext) {
    const readyState = this.state.ready;
    if (!this.options || !readyState) {
      return {
        status: 503,
        contentType: GRAPHQL_JSON_CONTENT_TYPE,
        body: { errors: [{ message: 'GraphQL runtime is not initialized.' }] },
      };
    }

    await this.emitEvent(
      context,
      new GraphqlRequestEvent({
        phase: GraphqlRequestPhase.Started,
        requestId: context.requestId,
        method: context.method,
        path: context.path,
      }),
    );

    try {
      const response = await this.executeRequest(context, readyState);
      await this.emitEvent(
        context,
        new GraphqlRequestEvent({
          phase: GraphqlRequestPhase.Completed,
          requestId: context.requestId,
          method: context.method,
          path: context.path,
          statusCode: response.status,
        }),
      );
      return response;
    } catch (error) {
      await this.emitEvent(
        context,
        new GraphqlRequestEvent({
          phase: GraphqlRequestPhase.Completed,
          requestId: context.requestId,
          method: context.method,
          path: context.path,
          statusCode: 500,
        }),
      );
      throw error;
    }
  }

  private async emitEvent(context: PluginRequestContext, event: GraphqlRequestEvent): Promise<void> {
    const sink = this.options?.onEvent;
    if (!sink) {
      return;
    }

    try {
      await sink(event);
    } catch (error) {
      context.logger?.warning('graphql telemetry hook failed', {
        request_id: context.requestId,
        path: context.path,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  private async executeRequest(context: PluginRequestContext, readyState: GraphqlReadyState) {
    const query = readQuery(context);
    if (!query) {
      return {
        status: 400,
        contentType: GRAPHQL_JSON_CONTENT_TYPE,
        body: { errors: [{ message: 'GraphQL request body must include a query string.' }] },
      };
    }

    let document: DocumentNode;
    try {
      document = parse(query);
    } catch (error) {
      return graphqlOkResponse({ errors: [formatGraphqlError(error)] });
    }

    const maxDepth = computeDocumentDepth(document);
    if (maxDepth > this.options!.maxDepth) {
      return graphqlOkResponse({
        errors: [
          validationError(
            `Maximum operation depth of ${this.options!.maxDepth} reached. Operation depth: ${maxDepth}.`,
            'queryDepthComplexity',
          ),
        ],
      });
    }

    const validationErrors = validate(
      readyState.schema,
      document,
      this.options!.introspectionEnabled ? specifiedRules : [...specifiedRules, NoSchemaIntrospectionCustomRule],
    );
    if (validationErrors.length > 0) {
      return graphqlOkResponse({ errors: validationErrors.map((error) => formatGraphqlError(error)) });
    }

    const complexity = computeDocumentComplexity(document);
    if (complexity > this.options!.maxComplexity) {
      return graphqlOkResponse({
        errors: [
          validationError(
            `Maximum operation complexity of ${this.options!.maxComplexity} reached. Operation complexity: ${complexity}.`,
            'queryComplexity',
          ),
        ],
      });
    }

    const result = await execute({
      schema: readyState.schema,
      document,
      operationName: readOperationName(context.body),
      variableValues: readVariables(context.body),
      rootValue: {},
      contextValue: {
        request: context,
        readyState,
        relationLoaders: new Map(),
      } satisfies GraphqlExecutionContext,
      fieldResolver: createFieldResolver(),
    });

    return graphqlOkResponse({
      data: result.data,
      errors: result.errors?.map((error) => formatGraphqlError(error)),
    });
  }
}

class GraphqlRuntimeHealthCheck extends HealthCheck {
  readonly name = 'graphql';

  constructor(private readonly statusReader: () => GraphqlRuntimeStatus) {
    super();
  }

  async check(): Promise<HealthCheckResult> {
    const status = this.statusReader();
    return new HealthCheckResult('pass', {
      output: status === 'disabled' ? 'disabled' : 'ready',
    });
  }
}

class RelationBatchLoader {
  private readonly cache = new Map<string, Promise<readonly Readonly<Record<string, unknown>>[]>>();
  private readonly queue = new Map<string, RelationBatchRequest[]>();
  private readonly keys = new Map<string, RelationParentKey>();
  private flushScheduled = false;

  constructor(
    private readonly options: {
      catalog: GraphqlCatalog;
      sourceObject: GraphqlPublishedObject;
      targetObject: GraphqlPublishedObject;
      relation: GraphqlCatalogRelation;
      projectedFields: readonly string[];
      dispatcher: SqlCatalogReadDispatcher;
      requestContext: PluginRequestContext;
    },
  ) {}

  load(key: RelationParentKey): Promise<readonly Readonly<Record<string, unknown>>[]> {
    const cached = this.cache.get(key.cacheKey);
    if (cached) {
      return cached;
    }

    const promise = new Promise<readonly Readonly<Record<string, unknown>>[]>((resolve, reject) => {
      const existing = this.queue.get(key.cacheKey);
      const request: RelationBatchRequest = { key, resolve, reject };
      if (existing) {
        existing.push(request);
      } else {
        this.queue.set(key.cacheKey, [request]);
        this.keys.set(key.cacheKey, key);
      }
      if (!this.flushScheduled) {
        this.flushScheduled = true;
        queueMicrotask(() => {
          void this.flush();
        });
      }
    });

    this.cache.set(key.cacheKey, promise);
    return promise;
  }

  private async flush(): Promise<void> {
    const entries = [...this.queue.entries()];
    const keys = [...this.keys.values()];
    this.queue.clear();
    this.keys.clear();
    this.flushScheduled = false;

    try {
      const rowSet = await this.options.dispatcher.readRelationBatch({
        catalog: this.options.catalog,
        selection: new SqlRelationBatchSelection({
          sourceObjectId: this.options.sourceObject.id,
          relationName: this.options.relation.name,
          projectedFields: this.options.projectedFields,
          parentKeys: keys.map((key) => key.values),
        }),
        context: buildExecutionContext(this.options.requestContext),
      });

      const groupedRows = groupRelationRows({
        rowSet,
        targetObject: this.options.targetObject,
        relation: this.options.relation,
      });

      for (const [cacheKey, requests] of entries) {
        const rows = groupedRows.get(cacheKey) ?? [];
        this.cache.set(cacheKey, Promise.resolve(rows));
        for (const request of requests) {
          request.resolve(rows);
        }
      }
    } catch (error) {
      for (const [cacheKey, requests] of entries) {
        this.cache.delete(cacheKey);
        for (const request of requests) {
          request.reject(error);
        }
      }
    }
  }
}

function buildResolverRegistry(options: {
  catalog: GraphqlCatalog;
  dispatcher: SqlCatalogReadDispatcher;
  options: GraphqlOptions;
}): ReadonlyMap<string, RuntimeFieldResolver> {
  const resolvers = new Map<string, RuntimeFieldResolver>();

  for (const object of options.catalog.objects) {
    if (object.graphql.itemField) {
      resolvers.set(`Query.${object.graphql.itemField}`, async (_source, args, context, info) =>
        resolveItem({
          args,
          context,
          info,
          catalog: options.catalog,
          object,
          dispatcher: options.dispatcher,
        }),
      );
    }

    resolvers.set(`Query.${object.graphql.collectionField}`, async (_source, args, context, info) =>
      resolveCollection({
        args,
        context,
        info,
        catalog: options.catalog,
        object,
        dispatcher: options.dispatcher,
        runtimeOptions: options.options,
      }),
    );

    for (const relation of object.relations) {
      resolvers.set(`${object.graphql.typeName}.${relation.name}`, async (source, _args, context, info) =>
        resolveRelation({
          source,
          context,
          info,
          catalog: options.catalog,
          sourceObject: object,
          relation,
          dispatcher: options.dispatcher,
        }),
      );
    }

    resolvers.set(`${object.graphql.typeName}List.totalCount`, async (source) => {
      if (!source || typeof source !== 'object') {
        return 0;
      }
      const thunk = (source as Record<PropertyKey, unknown>)[GRAPHQL_TOTAL_COUNT_THUNK_KEY];
      if (typeof thunk === 'function') {
        return thunk();
      }
      return 0;
    });
  }

  return resolvers;
}

function createFieldResolver(): GraphQLFieldResolver<unknown, GraphqlExecutionContext> {
  return async (source, args, context, info) => {
    const resolver = context.readyState.resolvers.get(`${info.parentType.name}.${info.fieldName}`);
    if (resolver) {
      return resolver(source, args as Record<string, unknown>, context, info);
    }
    return defaultFieldResolver(source, args, context, info);
  };
}

async function resolveItem(options: {
  args: Record<string, unknown>;
  context: GraphqlExecutionContext;
  info: GraphQLResolveInfo;
  catalog: GraphqlCatalog;
  object: GraphqlPublishedObject;
  dispatcher: SqlCatalogReadDispatcher;
}): Promise<unknown> {
  if (!isPlainObject(options.args.key)) {
    throw graphqlValidationError('graphql.key', 'GraphQL item queries require a key input object.');
  }

  const rowSet = await options.dispatcher.readItem({
    catalog: options.catalog,
    selection: new SqlItemSelection({
      objectId: options.object.id,
      projectedFields: projectedFieldsForObject({
        object: options.object,
        fieldNodes: options.info.fieldNodes,
        fragments: options.info.fragments,
      }),
      key: { ...options.args.key },
    }),
    context: buildExecutionContext(options.context.request),
  });

  return rowSet.rows[0] ?? null;
}

async function resolveCollection(options: {
  args: Record<string, unknown>;
  context: GraphqlExecutionContext;
  info: GraphQLResolveInfo;
  catalog: GraphqlCatalog;
  object: GraphqlPublishedObject;
  dispatcher: SqlCatalogReadDispatcher;
  runtimeOptions: GraphqlOptions;
}): Promise<Record<PropertyKey, unknown>> {
  const envelopeFields = collectSelectedFieldNodes(options.info.fieldNodes, options.info.fragments);
  const itemFieldNodes = envelopeFields.get('items') ?? [];
  const wantsTotalCount = envelopeFields.has('totalCount');
  const filter = parseFilter(options.object, options.args.filter);
  const orderBy = parseOrderBy(options.object, options.args.orderBy);
  const page = parsePage(options.object, options.args.page, options.runtimeOptions);

  let items: readonly Readonly<Record<string, unknown>>[] = [];
  if (itemFieldNodes.length > 0 && page.limit > 0) {
    const rowSet = await options.dispatcher.readCollection({
      catalog: options.catalog,
      selection: new SqlCollectionSelection({
        objectId: options.object.id,
        projectedFields: projectedFieldsForObject({
          object: options.object,
          fieldNodes: itemFieldNodes,
          fragments: options.info.fragments,
        }),
        filter,
        orderBy,
        page,
      }),
      context: buildExecutionContext(options.context.request),
    });
    items = rowSet.rows;
  }

  const envelope: Record<PropertyKey, unknown> = { items };
  if (wantsTotalCount) {
    envelope[GRAPHQL_TOTAL_COUNT_THUNK_KEY] = async () => {
      const rowSet = await options.dispatcher.readCount({
        catalog: options.catalog,
        selection: new SqlCountSelection({
          objectId: options.object.id,
          filter,
        }),
        context: buildExecutionContext(options.context.request),
      });
      return extractTotalCount(rowSet);
    };
  }

  return envelope;
}

async function resolveRelation(options: {
  source: unknown;
  context: GraphqlExecutionContext;
  info: GraphQLResolveInfo;
  catalog: GraphqlCatalog;
  sourceObject: GraphqlPublishedObject;
  relation: GraphqlCatalogRelation;
  dispatcher: SqlCatalogReadDispatcher;
}): Promise<unknown> {
  if (!isPlainObject(options.source)) {
    return options.relation.cardinality === GraphqlCatalogRelationCardinality.Many ? [] : null;
  }

  const targetObject = objectById(options.catalog, options.relation.target);
  const requiredPublicFields = options.relation.targetFields.map(
    (column) => fieldByColumn(targetObject, column).publicName,
  );
  const projectedFields = projectedFieldsForObject({
    object: targetObject,
    fieldNodes: options.info.fieldNodes,
    fragments: options.info.fragments,
    requiredPublicFields,
  });
  const parentValues = relationParentValues({
    sourceObject: options.sourceObject,
    relation: options.relation,
    parent: options.source,
  });
  const loader = relationLoader({
    executionContext: options.context,
    catalog: options.catalog,
    sourceObject: options.sourceObject,
    targetObject,
    relation: options.relation,
    projectedFields,
    dispatcher: options.dispatcher,
  });
  const rows = await loader.load({
    cacheKey: relationKeyFromValues(parentValues),
    values: parentValues,
  });

  if (options.relation.cardinality === GraphqlCatalogRelationCardinality.Many) {
    return rows;
  }

  return rows[0] ?? null;
}

function relationLoader(options: {
  executionContext: GraphqlExecutionContext;
  catalog: GraphqlCatalog;
  sourceObject: GraphqlPublishedObject;
  targetObject: GraphqlPublishedObject;
  relation: GraphqlCatalogRelation;
  projectedFields: readonly string[];
  dispatcher: SqlCatalogReadDispatcher;
}): RelationBatchLoader {
  const loaderId = [options.sourceObject.id, options.relation.name, options.projectedFields.join(',')].join('|');
  const existing = options.executionContext.relationLoaders.get(loaderId);
  if (existing) {
    return existing;
  }

  const loader = new RelationBatchLoader({
    catalog: options.catalog,
    sourceObject: options.sourceObject,
    targetObject: options.targetObject,
    relation: options.relation,
    projectedFields: options.projectedFields,
    dispatcher: options.dispatcher,
    requestContext: options.executionContext.request,
  });
  options.executionContext.relationLoaders.set(loaderId, loader);
  return loader;
}

function projectedFieldsForObject(options: {
  object: GraphqlPublishedObject;
  fieldNodes: readonly FieldNode[];
  fragments: Record<string, FragmentDefinitionNode>;
  requiredPublicFields?: Iterable<string>;
}): string[] {
  const projected = new Set<string>(options.requiredPublicFields ?? []);
  for (const column of options.object.identity.fields) {
    projected.add(fieldByColumn(options.object, column).publicName);
  }

  const selected = collectSelectedFieldNodes(options.fieldNodes, options.fragments);
  for (const field of options.object.fields) {
    if (selected.has(field.publicName)) {
      projected.add(field.publicName);
    }
  }

  for (const relation of options.object.relations) {
    if (!selected.has(relation.name)) {
      continue;
    }
    for (const column of relation.sourceFields) {
      projected.add(fieldByColumn(options.object, column).publicName);
    }
  }

  return options.object.fields
    .filter((field) => projected.has(field.publicName))
    .map((field) => field.publicName);
}

function collectSelectedFieldNodes(
  fieldNodes: readonly FieldNode[],
  fragments: Record<string, FragmentDefinitionNode>,
): Map<string, FieldNode[]> {
  const collected = new Map<string, FieldNode[]>();
  const visitedFragments = new Set<string>();

  for (const fieldNode of fieldNodes) {
    collectSelectionSet(fieldNode.selectionSet, fragments, collected, visitedFragments);
  }

  return collected;
}

function collectSelectionSet(
  selectionSet: SelectionSetNode | undefined,
  fragments: Record<string, FragmentDefinitionNode>,
  collected: Map<string, FieldNode[]>,
  visitedFragments: Set<string>,
): void {
  if (!selectionSet) {
    return;
  }

  for (const selection of selectionSet.selections) {
    switch (selection.kind) {
      case Kind.FIELD: {
        const existing = collected.get(selection.name.value);
        if (existing) {
          existing.push(selection);
        } else {
          collected.set(selection.name.value, [selection]);
        }
        break;
      }
      case Kind.INLINE_FRAGMENT:
        collectSelectionSet(selection.selectionSet, fragments, collected, visitedFragments);
        break;
      case Kind.FRAGMENT_SPREAD: {
        if (visitedFragments.has(selection.name.value)) {
          break;
        }
        visitedFragments.add(selection.name.value);
        collectSelectionSet(fragments[selection.name.value]?.selectionSet, fragments, collected, visitedFragments);
        break;
      }
    }
  }
}

function parseFilter(object: GraphqlPublishedObject, raw: unknown): SqlFilterCondition | SqlFilterGroup | undefined {
  if (raw == null) {
    return undefined;
  }
  if (!isPlainObject(raw)) {
    throw graphqlValidationError('graphql.filter', 'GraphQL filter input must be an object.');
  }

  const nodes: Array<SqlFilterCondition | SqlFilterGroup> = [];
  for (const [key, value] of Object.entries(raw)) {
    switch (key) {
      case 'and': {
        const children = Array.isArray(value)
          ? value.map((child) => parseFilter(object, child)).filter((child): child is SqlFilterCondition | SqlFilterGroup => !!child)
          : [];
        if (children.length > 0) {
          nodes.push(SqlFilterGroup.and(children));
        }
        break;
      }
      case 'or': {
        const children = Array.isArray(value)
          ? value.map((child) => parseFilter(object, child)).filter((child): child is SqlFilterCondition | SqlFilterGroup => !!child)
          : [];
        if (children.length > 0) {
          nodes.push(SqlFilterGroup.or(children));
        }
        break;
      }
      case 'not': {
        const child = parseFilter(object, value);
        if (child) {
          nodes.push(SqlFilterGroup.not(child));
        }
        break;
      }
      default: {
        const field = fieldByPublicName(object, key);
        if (!field.filterable) {
          throw graphqlValidationError('graphql.filter', `Field ${field.publicName} is not filterable.`);
        }
        if (!isPlainObject(value)) {
          throw graphqlValidationError(
            'graphql.filter',
            `Filter operators for ${field.publicName} must be an object.`,
          );
        }

        const conditions = Object.entries(value).map(
          ([operatorName, operatorValue]) =>
            new SqlFilterCondition({
              field: field.publicName,
              operator: parseFilterOperator(operatorName),
              value: operatorValue,
            }),
        );
        if (conditions.length === 1) {
          nodes.push(conditions[0]!);
        } else if (conditions.length > 1) {
          nodes.push(SqlFilterGroup.and(conditions));
        }
      }
    }
  }

  if (nodes.length === 0) {
    return undefined;
  }
  return nodes.length === 1 ? nodes[0] : SqlFilterGroup.and(nodes);
}

function parseFilterOperator(name: string): SqlFilterOperator {
  switch (name) {
    case 'eq':
      return SqlFilterOperator.Eq;
    case 'ne':
      return SqlFilterOperator.Ne;
    case 'in':
      return SqlFilterOperator.InList;
    case 'lt':
      return SqlFilterOperator.Lt;
    case 'lte':
      return SqlFilterOperator.Lte;
    case 'gt':
      return SqlFilterOperator.Gt;
    case 'gte':
      return SqlFilterOperator.Gte;
    case 'isNull':
      return SqlFilterOperator.IsNull;
    case 'contains':
      return SqlFilterOperator.Contains;
    case 'startsWith':
      return SqlFilterOperator.StartsWith;
    case 'endsWith':
      return SqlFilterOperator.EndsWith;
    default:
      throw graphqlValidationError('graphql.filter', `Unsupported filter operator ${name}.`);
  }
}

function parseOrderBy(object: GraphqlPublishedObject, raw: unknown): readonly SqlOrderByClause[] {
  if (raw == null) {
    return [];
  }
  if (!Array.isArray(raw)) {
    throw graphqlValidationError('graphql.orderBy', 'GraphQL orderBy input must be a list.');
  }

  return raw.map((entry) => {
    if (!isPlainObject(entry)) {
      throw graphqlValidationError('graphql.orderBy', 'Each orderBy entry must be an object.');
    }
    const fieldName = entry.field;
    const direction = entry.direction;
    if (typeof fieldName !== 'string' || typeof direction !== 'string') {
      throw graphqlValidationError(
        'graphql.orderBy',
        'Each orderBy entry must define field and direction.',
      );
    }

    const field = fieldByPublicName(object, fieldName);
    if (!field.sortable) {
      throw graphqlValidationError('graphql.orderBy', `Field ${field.publicName} is not sortable.`);
    }

    return new SqlOrderByClause({
      field: field.publicName,
      direction: direction === 'DESC' ? SqlSortDirection.Desc : SqlSortDirection.Asc,
    });
  });
}

function parsePage(object: GraphqlPublishedObject, raw: unknown, options: GraphqlOptions): SqlPage {
  const effectiveMax = Math.min(object.capabilities.pagination.maxLimit, options.maxLimit);
  const effectiveDefault = Math.min(object.capabilities.pagination.defaultLimit, options.defaultLimit, effectiveMax);

  if (raw == null) {
    return new SqlPage({ limit: effectiveDefault, offset: 0 });
  }
  if (!isPlainObject(raw)) {
    throw graphqlValidationError('graphql.page', 'GraphQL page input must be an object.');
  }

  const limit = typeof raw.limit === 'number' ? raw.limit : effectiveDefault;
  const offset = typeof raw.offset === 'number' ? raw.offset : 0;
  if (limit < 0 || offset < 0) {
    throw graphqlValidationError('graphql.page', 'GraphQL page limit and offset must be non-negative.');
  }
  if (limit > effectiveMax) {
    throw graphqlValidationError(
      'graphql.page',
      `Requested page limit ${limit} exceeds the effective max limit ${effectiveMax}.`,
    );
  }

  return new SqlPage({ limit, offset });
}

function buildExecutionContext(context: PluginRequestContext): ReadExecutionContext {
  return new ReadExecutionContext({
    requestId: headerValue(context, 'x-request-id') ?? context.requestId,
    tenantId: headerValue(context, 'x-tenant-id'),
    principal: headerValue(context, 'x-principal'),
    telemetry: context.logger,
  });
}

function headerValue(context: PluginRequestContext, name: string): string | undefined {
  const raw = Object.entries(context.headers).find(([key]) => key.toLowerCase() === name)?.[1];
  if (typeof raw === 'string') {
    return raw;
  }
  return Array.isArray(raw) ? raw[0] : undefined;
}

function groupRelationRows(options: {
  rowSet: RowSet;
  targetObject: GraphqlPublishedObject;
  relation: GraphqlCatalogRelation;
}): Map<string, readonly Readonly<Record<string, unknown>>[]> {
  const grouped = new Map<string, Readonly<Record<string, unknown>>[]>();
  for (const row of options.rowSet.rows) {
    const key = relationKeyFromValues(
      Object.fromEntries(
        options.relation.targetFields.map((column) => {
          const field = fieldByColumn(options.targetObject, column);
          return [field.publicName, row[field.publicName]];
        }),
      ),
    );
    const existing = grouped.get(key);
    if (existing) {
      grouped.set(key, [...existing, row]);
    } else {
      grouped.set(key, [row]);
    }
  }
  return grouped;
}

function relationParentValues(options: {
  sourceObject: GraphqlPublishedObject;
  relation: GraphqlCatalogRelation;
  parent: Readonly<Record<string, unknown>>;
}): Readonly<Record<string, unknown>> {
  const values: Record<string, unknown> = {};
  for (const column of options.relation.sourceFields) {
    const publicName = fieldByColumn(options.sourceObject, column).publicName;
    values[publicName] = options.parent[publicName];
  }
  return values;
}

function relationKeyFromValues(values: Readonly<Record<string, unknown>>): string {
  return JSON.stringify(
    Object.keys(values)
      .sort((left, right) => left.localeCompare(right))
      .map((key) => [key, values[key] ?? null]),
  );
}

function extractTotalCount(rowSet: RowSet): number {
  if (rowSet.rows.length === 0) {
    return 0;
  }
  const value = rowSet.rows[0]?.totalCount;
  if (typeof value === 'number') {
    return value;
  }
  throw new Error(`Expected totalCount to be numeric, got ${String(value)}.`);
}

function fieldByColumn(object: GraphqlPublishedObject, column: string): GraphqlCatalogField {
  const field = object.fields.find((candidate) => candidate.column === column);
  if (!field) {
    throw new Error(`Unknown source column ${column} for ${object.id}.`);
  }
  return field;
}

function fieldByPublicName(object: GraphqlPublishedObject, publicName: string): GraphqlCatalogField {
  const field = object.fields.find((candidate) => candidate.publicName === publicName);
  if (!field) {
    throw new Error(`Unknown public field ${publicName} for ${object.id}.`);
  }
  return field;
}

function objectById(catalog: GraphqlCatalog, objectId: string): GraphqlPublishedObject {
  const object = catalog.objects.find((candidate) => candidate.id === objectId);
  if (!object) {
    throw new Error(`Unknown catalog object ${objectId}.`);
  }
  return object;
}

function readQuery(context: PluginRequestContext): string | undefined {
  if (isPlainObject(context.body) && typeof context.body.query === 'string') {
    return context.body.query;
  }
  const query = context.query.query;
  return typeof query === 'string' ? query : undefined;
}

function readOperationName(body: unknown): string | undefined {
  return isPlainObject(body) && typeof body.operationName === 'string' ? body.operationName : undefined;
}

function readVariables(body: unknown): Record<string, unknown> | undefined {
  return isPlainObject(body) && isPlainObject(body.variables) ? { ...body.variables } : undefined;
}

function computeDocumentDepth(document: DocumentNode): number {
  const fragments = collectFragments(document);
  const visitedFragments = new Set<string>();
  let maxDepth = 0;

  for (const definition of document.definitions) {
    if (definition.kind !== Kind.OPERATION_DEFINITION) {
      continue;
    }
    maxDepth = Math.max(maxDepth, selectionSetDepth(definition.selectionSet, fragments, visitedFragments, 0));
  }

  return maxDepth;
}

function selectionSetDepth(
  selectionSet: SelectionSetNode,
  fragments: Record<string, FragmentDefinitionNode>,
  visitedFragments: Set<string>,
  currentDepth: number,
): number {
  let maxDepth = currentDepth;
  for (const selection of selectionSet.selections) {
    switch (selection.kind) {
      case Kind.FIELD: {
        const nextDepth = currentDepth + 1;
        maxDepth = Math.max(maxDepth, nextDepth);
        if (selection.selectionSet) {
          maxDepth = Math.max(maxDepth, selectionSetDepth(selection.selectionSet, fragments, visitedFragments, nextDepth));
        }
        break;
      }
      case Kind.INLINE_FRAGMENT:
        maxDepth = Math.max(maxDepth, selectionSetDepth(selection.selectionSet, fragments, visitedFragments, currentDepth));
        break;
      case Kind.FRAGMENT_SPREAD: {
        if (visitedFragments.has(selection.name.value)) {
          break;
        }
        visitedFragments.add(selection.name.value);
        const fragment = fragments[selection.name.value];
        if (fragment) {
          maxDepth = Math.max(maxDepth, selectionSetDepth(fragment.selectionSet, fragments, visitedFragments, currentDepth));
        }
        break;
      }
    }
  }
  return maxDepth;
}

function computeDocumentComplexity(document: DocumentNode): number {
  const fragments = collectFragments(document);
  const visitedFragments = new Set<string>();
  let complexity = 0;

  for (const definition of document.definitions) {
    if (definition.kind !== Kind.OPERATION_DEFINITION) {
      continue;
    }
    complexity += selectionSetComplexity(definition.selectionSet, fragments, visitedFragments, 1);
  }

  return complexity;
}

function selectionSetComplexity(
  selectionSet: SelectionSetNode,
  fragments: Record<string, FragmentDefinitionNode>,
  visitedFragments: Set<string>,
  currentDepth: number,
): number {
  let complexity = 0;
  for (const selection of selectionSet.selections) {
    switch (selection.kind) {
      case Kind.FIELD:
        complexity += currentDepth;
        if (selection.selectionSet) {
          complexity += selectionSetComplexity(selection.selectionSet, fragments, visitedFragments, currentDepth + 1);
        }
        break;
      case Kind.INLINE_FRAGMENT:
        complexity += selectionSetComplexity(selection.selectionSet, fragments, visitedFragments, currentDepth);
        break;
      case Kind.FRAGMENT_SPREAD: {
        if (visitedFragments.has(selection.name.value)) {
          break;
        }
        visitedFragments.add(selection.name.value);
        const fragment = fragments[selection.name.value];
        if (fragment) {
          complexity += selectionSetComplexity(fragment.selectionSet, fragments, visitedFragments, currentDepth);
        }
        break;
      }
    }
  }
  return complexity;
}

function collectFragments(document: DocumentNode): Record<string, FragmentDefinitionNode> {
  const fragments: Record<string, FragmentDefinitionNode> = {};
  for (const definition of document.definitions) {
    if (definition.kind === Kind.FRAGMENT_DEFINITION) {
      fragments[definition.name.value] = definition;
    }
  }
  return fragments;
}

function graphqlOkResponse(body: GraphqlResponseBody) {
  return {
    status: 200,
    contentType: GRAPHQL_JSON_CONTENT_TYPE,
    body,
  };
}

function validationError(message: string, code: string): Record<string, unknown> {
  return {
    message,
    extensions: {
      validationError: {
        code,
      },
    },
  };
}

function formatGraphqlError(error: unknown): Record<string, unknown> {
  if (error instanceof GraphQLError) {
    const formatted = error.toJSON();
    return {
      ...formatted,
      ...(formatted.extensions ? { extensions: { ...formatted.extensions } } : {}),
    };
  }
  if (error instanceof Error) {
    return { message: error.message };
  }
  return { message: String(error) };
}

function graphqlValidationError(code: string, message: string): GraphQLError {
  return new GraphQLError(message, { extensions: { code } });
}

function validateGeneratedSdl(sdl: string): void {
  if (!sdl.trim()) {
    throw new Error('GraphQL schema generation failed: Generated SDL must not be empty.');
  }
  if (!/type\s+Query\s*\{/.test(sdl)) {
    throw new Error('GraphQL schema generation failed: Generated SDL must declare a Query root type.');
  }

  let depth = 0;
  for (const char of sdl) {
    if (char === '{') {
      depth += 1;
    } else if (char === '}') {
      depth -= 1;
      if (depth < 0) {
        throw new Error('GraphQL schema generation failed: Generated SDL has unmatched closing brace.');
      }
    }
  }
  if (depth !== 0) {
    throw new Error('GraphQL schema generation failed: Generated SDL has unmatched opening brace.');
  }
}

function isReadExecutor(value: unknown): value is ReadExecutor {
  return !!value && typeof value === 'object' && typeof (value as ReadExecutor).execute === 'function';
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === 'object' && !Array.isArray(value);
}