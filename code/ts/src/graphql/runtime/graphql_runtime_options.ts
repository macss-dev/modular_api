import type { GraphqlCatalog } from '../catalog/graphql_catalog_builder';
import type { ReadExecutor } from '../read/sql_read_contract';
import { GraphqlSchemaSdlGenerator } from '../schema/graphql_schema_sdl_generator';

export const graphqlDefaultReadExecutorCapabilityId = 'modular_api.sql.read_executor';

export class GraphqlOptions {
  readonly catalogFactory: () => Promise<GraphqlCatalog>;
  readonly executor?: ReadExecutor;
  readonly executionCapabilityId?: string;
  readonly introspectionEnabled: boolean;
  readonly maxDepth: number;
  readonly maxComplexity: number;
  readonly sdlFactory: (catalog: GraphqlCatalog) => string;

  constructor(options: {
    catalogFactory: () => Promise<GraphqlCatalog>;
    executor?: ReadExecutor;
    executionCapabilityId?: string;
    introspectionEnabled?: boolean;
    maxDepth?: number;
    maxComplexity?: number;
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
    this.sdlFactory = options.sdlFactory ?? ((catalog) => new GraphqlSchemaSdlGenerator().generate(catalog));
  }
}