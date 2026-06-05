import type { GraphqlCatalog } from '../catalog/graphql_catalog_builder';
import type { ReadExecutor } from '../read/sql_read_contract';
import { GraphqlSchemaSdlGenerator } from '../schema/graphql_schema_sdl_generator';

export type GraphqlEventSink = (event: GraphqlRequestEvent) => void | Promise<void>;
export type GraphqlSourceDigestFactory = () => string | Promise<string>;

export enum GraphqlRequestPhase {
  Started = 'started',
  Completed = 'completed',
}

export class GraphqlRequestEvent {
  readonly phase: GraphqlRequestPhase;
  readonly requestId: string;
  readonly method: string;
  readonly path: string;
  readonly statusCode?: number;

  constructor(options: {
    phase: GraphqlRequestPhase;
    requestId: string;
    method: string;
    path: string;
    statusCode?: number;
  }) {
    this.phase = options.phase;
    this.requestId = options.requestId;
    this.method = options.method;
    this.path = options.path;
    this.statusCode = options.statusCode;
  }
}

export const graphqlDefaultReadExecutorCapabilityId = 'modular_api.sql.read_executor';

export class GraphqlOptions {
  readonly catalogFactory: () => Promise<GraphqlCatalog>;
  readonly executor?: ReadExecutor;
  readonly executionCapabilityId?: string;
  readonly introspectionEnabled: boolean;
  readonly maxDepth: number;
  readonly maxComplexity: number;
  readonly defaultLimit: number;
  readonly maxLimit: number;
  readonly onEvent?: GraphqlEventSink;
  readonly artifactDirectory?: string;
  readonly sourceDigestFactory?: GraphqlSourceDigestFactory;
  readonly sdlFactory: (catalog: GraphqlCatalog) => string;

  constructor(options: {
    catalogFactory: () => Promise<GraphqlCatalog>;
    executor?: ReadExecutor;
    executionCapabilityId?: string;
    introspectionEnabled?: boolean;
    maxDepth?: number;
    maxComplexity?: number;
    defaultLimit?: number;
    maxLimit?: number;
    onEvent?: GraphqlEventSink;
    artifactDirectory?: string;
    sourceDigestFactory?: GraphqlSourceDigestFactory;
    sdlFactory?: (catalog: GraphqlCatalog) => string;
  }) {
    if (options.executor && options.executionCapabilityId) {
      throw new Error(
        'GraphQL runtime accepts either a direct executor or an execution capability id, not both.',
      );
    }

    this.catalogFactory = options.catalogFactory;
    this.executor = options.executor;
    this.executionCapabilityId = options.executionCapabilityId;
    this.introspectionEnabled = options.introspectionEnabled ?? false;
    this.maxDepth = options.maxDepth ?? 8;
    this.maxComplexity = options.maxComplexity ?? 500;
    this.defaultLimit = options.defaultLimit ?? 50;
    this.maxLimit = options.maxLimit ?? 200;
    this.onEvent = options.onEvent;
    this.artifactDirectory = options.artifactDirectory;
    this.sourceDigestFactory = options.sourceDigestFactory;
    this.sdlFactory = options.sdlFactory ?? ((catalog) => new GraphqlSchemaSdlGenerator().generate(catalog));
  }

  get resolvedExecutionCapabilityId(): string {
    return this.executionCapabilityId ?? graphqlDefaultReadExecutorCapabilityId;
  }
}