import { HealthCheck, HealthCheckResult } from '../../core/health/health_check';
import type { HealthService } from '../../core/health/health_service';
import type { Plugin, PluginHost, PluginManifest, PluginRequestContext, PluginValidationResult } from '../../core/plugin';
import type { GraphqlCatalog } from '../catalog/graphql_catalog_builder';
import type { ReadExecutor } from '../read/sql_read_contract';
import { GraphqlOptions, graphqlDefaultReadExecutorCapabilityId } from './graphql_runtime_options';

type GraphqlRuntimeStatus = 'disabled' | 'ready';

interface GraphqlRuntimeState {
  status: GraphqlRuntimeStatus;
  catalog?: GraphqlCatalog;
  executor?: ReadExecutor;
  sdl?: string;
}

const OFFICIAL_PLUGIN_HOST_RANGE = '>=0.1.0 <0.2.0';

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

    let executor: ReadExecutor | undefined;
    if (this.options.executor) {
      executor = this.options.executor;
    } else {
      const capabilityId = this.options.executionCapabilityId ?? graphqlDefaultReadExecutorCapabilityId;
      const capability = host.resolveCapability(capabilityId);
      if (!capability) {
        return [this.validationFailure(capabilityId, `Missing GraphQL read executor capability: ${capabilityId}`)];
      }
      if (!this.isReadExecutor(capability.value)) {
        return [
          this.validationFailure(capabilityId, `Capability ${capabilityId} does not expose a ReadExecutor.`),
        ];
      }
      executor = capability.value;
    }

    try {
      const catalog = await this.options.catalogFactory();
      let sdl: string;
      try {
        sdl = this.options.sdlFactory(catalog);
        validateGeneratedSdl(sdl);
      } catch (error) {
        return [
          this.validationFailure(
            'graphql.schema',
            `GraphQL schema generation failed: ${error instanceof Error ? error.message : String(error)}`,
          ),
        ];
      }

      this.state.status = 'ready';
      this.state.catalog = catalog;
      this.state.executor = executor;
      this.state.sdl = sdl;
      return [];
    } catch (error) {
      return [
        this.validationFailure(
          'graphql.catalog',
          `GraphQL catalog construction failed: ${error instanceof Error ? error.message : String(error)}`,
        ),
      ];
    }
  }

  private validationFailure(resourceId: string, message: string): PluginValidationResult {
    return {
      code: 'PLUGIN_VALIDATION_FAILED',
      message,
      pluginId: this.manifest.id,
      resourceId,
    };
  }

  private isReadExecutor(value: unknown): value is ReadExecutor {
    return !!value && typeof value === 'object' && typeof (value as ReadExecutor).execute === 'function';
  }

  private async handleRequest(context: PluginRequestContext) {
    const query = readQuery(context.body);
    if (!query) {
      return {
        status: 400,
        contentType: 'application/json; charset=utf-8',
        body: { errors: [{ message: 'GraphQL request body must include a query string.' }] },
      };
    }

    if (query.includes('__typename')) {
      return {
        status: 200,
        contentType: 'application/json; charset=utf-8',
        body: { data: { __typename: 'Query' } },
      };
    }

    return {
      status: 400,
      contentType: 'application/json; charset=utf-8',
      body: { errors: [{ message: 'Stage 6 runtime only supports the __typename readiness probe.' }] },
    };
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

function readQuery(body: unknown): string | undefined {
  if (!body || typeof body !== 'object') {
    return undefined;
  }
  const query = (body as Record<string, unknown>).query;
  return typeof query === 'string' ? query : undefined;
}

function validateGeneratedSdl(sdl: string): void {
  if (!sdl.trim()) {
    throw new Error('Generated SDL must not be empty.');
  }
  if (!/type\s+Query\s*\{/.test(sdl)) {
    throw new Error('Generated SDL must declare a Query root type.');
  }

  let depth = 0;
  for (const char of sdl) {
    if (char === '{') {
      depth += 1;
    } else if (char === '}') {
      depth -= 1;
      if (depth < 0) {
        throw new Error('Generated SDL has unmatched closing brace.');
      }
    }
  }
  if (depth !== 0) {
    throw new Error('Generated SDL has unmatched opening brace.');
  }
}