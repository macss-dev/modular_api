import { buildOpenApiSpec, jsonToYaml } from '../openapi/openapi';
import { buildSwaggerDocsHtml } from '../openapi/swagger_docs';
import type { HealthService } from './health/health_service';
import type { Counter, Gauge, Histogram } from './metrics/metric';
import { metricsMiddleware } from './metrics/metrics_middleware';
import type { MetricRegistry } from './metrics/metric_registry';
import { apiRegistry } from './registry';
import type { CapabilityHandle, Plugin, PluginHost, PluginManifest } from './plugin';

const OPENAPI_SPEC_CAPABILITY_ID = 'modular_api.openapi.spec';
const OFFICIAL_PLUGIN_HOST_RANGE = '>=0.1.0 <0.2.0';

export interface OperationalRoutePaths {
  healthPath: string;
  docsPath: string;
  openApiJsonPath: string;
  openApiYamlPath: string;
  metricsPath?: string;
}

interface BuildRuntimePluginsOptions {
  basePath: string;
  title: string;
  version: string;
  port: number;
  servers?: Array<{ url: string; description?: string }>;
  healthService: HealthService;
  metrics?: {
    path: string;
    registry: MetricRegistry;
    requestsTotal: Counter;
    requestsInFlight: Gauge;
    requestDuration: Histogram;
    excludedRoutes: string[];
  };
}

interface OpenApiSpecCapabilityValue {
  spec: Record<string, unknown>;
  yaml: string;
  specUrl: string;
}

export function operationalRoutePaths(basePath: string, metricsPath?: string): OperationalRoutePaths {
  return {
    healthPath: joinPath(basePath, '/health'),
    docsPath: joinPath(basePath, '/docs'),
    openApiJsonPath: joinPath(basePath, '/openapi.json'),
    openApiYamlPath: joinPath(basePath, '/openapi.yaml'),
    metricsPath: metricsPath ? joinPath(basePath, metricsPath) : undefined,
  };
}

export function buildRuntimePlugins(options: BuildRuntimePluginsOptions): Plugin[] {
  const plugins: Plugin[] = [new HealthRuntimePlugin(options.healthService)];

  if (options.metrics) {
    plugins.push(new MetricsRuntimePlugin(options.basePath, options.metrics));
  }

  plugins.push(
    new OpenApiRuntimePlugin({
      basePath: options.basePath,
      title: options.title,
      version: options.version,
      port: options.port,
      servers: options.servers,
    }),
    new DocsRuntimePlugin(),
  );

  return plugins;
}

class HealthRuntimePlugin implements Plugin {
  readonly manifest: PluginManifest = {
    id: 'modular_api.health',
    displayName: 'Health Plugin',
    version: '0.1.0',
    hostApiVersion: OFFICIAL_PLUGIN_HOST_RANGE,
  };

  constructor(private readonly healthService: HealthService) {}

  setup(host: PluginHost): void {
    host.registerRoute({
      id: 'health.endpoint',
      method: 'GET',
      path: '/health',
      visibility: 'operational',
      handler: async () => {
        const health = await this.healthService.evaluate();
        return {
          status: health.httpStatusCode,
          contentType: 'application/health+json; charset=utf-8',
          body: health.toJson(),
        };
      },
    });
  }
}

class MetricsRuntimePlugin implements Plugin {
  readonly manifest: PluginManifest = {
    id: 'modular_api.metrics',
    displayName: 'Metrics Plugin',
    version: '0.1.0',
    hostApiVersion: OFFICIAL_PLUGIN_HOST_RANGE,
  };

  constructor(
    private readonly basePath: string,
    private readonly options: BuildRuntimePluginsOptions['metrics'],
  ) {}

  setup(host: PluginHost): void {
    if (!this.options) {
      return;
    }

    const paths = operationalRoutePaths(this.basePath, this.options.path);
    const configuredExcluded = this.options.excludedRoutes.map((route) => joinPath(this.basePath, route));
    const excludedRoutes = [...new Set([
      ...configuredExcluded,
      paths.healthPath,
      paths.docsPath,
      paths.openApiJsonPath,
      paths.openApiYamlPath,
      ...(paths.metricsPath ? [paths.metricsPath] : []),
    ])];

    host.registerMiddleware({
      id: 'metrics.middleware',
      slot: 'preRouting',
      order: 0,
      handler: metricsMiddleware({
        requestsTotal: this.options.requestsTotal,
        requestsInFlight: this.options.requestsInFlight,
        requestDuration: this.options.requestDuration,
        excludedRoutes,
        registeredPaths: apiRegistry.routes.map((route) => route.path),
      }),
    });

    host.registerRoute({
      id: 'metrics.endpoint',
      method: 'GET',
      path: this.options.path,
      visibility: 'operational',
      handler: () => ({
        status: 200,
        contentType: 'text/plain; version=0.0.4; charset=utf-8',
        body: this.options?.registry.serialize(),
      }),
    });
  }
}

class OpenApiRuntimePlugin implements Plugin {
  readonly manifest: PluginManifest = {
    id: 'modular_api.openapi',
    displayName: 'OpenAPI Plugin',
    version: '0.1.0',
    hostApiVersion: OFFICIAL_PLUGIN_HOST_RANGE,
  };

  constructor(
    private readonly options: {
      basePath: string;
      title: string;
      version: string;
      port: number;
      servers?: Array<{ url: string; description?: string }>;
    },
  ) {}

  setup(host: PluginHost): void {
    const spec = buildOpenApiSpec({
      title: this.options.title,
      port: this.options.port,
      version: this.options.version,
      servers: this.options.servers,
    });
    const yaml = jsonToYaml(spec);
    const specUrl = operationalRoutePaths(this.options.basePath).openApiJsonPath;

    host.exposeCapability({
      id: OPENAPI_SPEC_CAPABILITY_ID,
      version: '1.0.0',
      value: { spec, yaml, specUrl },
    });

    host.registerRoute({
      id: 'openapi.json.endpoint',
      method: 'GET',
      path: '/openapi.json',
      visibility: 'operational',
      handler: () => ({
        status: 200,
        contentType: 'application/json; charset=utf-8',
        body: spec,
      }),
    });

    host.registerRoute({
      id: 'openapi.yaml.endpoint',
      method: 'GET',
      path: '/openapi.yaml',
      visibility: 'operational',
      handler: () => ({
        status: 200,
        contentType: 'application/x-yaml; charset=utf-8',
        body: yaml,
      }),
    });
  }
}

class DocsRuntimePlugin implements Plugin {
  readonly manifest: PluginManifest = {
    id: 'modular_api.docs',
    displayName: 'Docs Plugin',
    version: '0.1.0',
    hostApiVersion: OFFICIAL_PLUGIN_HOST_RANGE,
  };

  setup(host: PluginHost): void {
    const specCapability = host.requireCapability(OPENAPI_SPEC_CAPABILITY_ID) as CapabilityHandle<OpenApiSpecCapabilityValue>;
    const html = buildSwaggerDocsHtml({
      title: host.metadata().title,
      specUrl: specCapability.value.specUrl,
    });

    host.registerRoute({
      id: 'docs.endpoint',
      method: 'GET',
      path: '/docs',
      visibility: 'operational',
      handler: () => ({
        status: 200,
        contentType: 'text/html; charset=utf-8',
        body: html,
      }),
    });
  }
}

function normalizeBasePath(basePath: string): string {
  if (!basePath || basePath === '/') {
    return '/';
  }

  return `/${basePath.trim().replace(/^\/+|\/+$/g, '')}`;
}

function normalizeRelativePath(path: string): string {
  const trimmed = path.trim();
  if (!trimmed) {
    throw new Error('Plugin route path cannot be empty');
  }

  return `/${trimmed.replace(/^\/+|\/+$/g, '')}`;
}

function joinPath(basePath: string, relativePath: string): string {
  const normalizedBasePath = normalizeBasePath(basePath);
  const normalizedRelativePath = normalizeRelativePath(relativePath);

  if (normalizedBasePath === '/') {
    return normalizedRelativePath;
  }

  return `${normalizedBasePath}${normalizedRelativePath}`.replace(/\/+/g, '/');
}