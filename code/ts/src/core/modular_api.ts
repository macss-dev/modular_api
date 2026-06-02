// ============================================================
// core/modular_api.ts
// ModularApi — main orchestrator.
// Mirror of ModularApi in Dart.
// ============================================================

import express, { type Express, type RequestHandler, type Router } from 'express';
import { ModuleBuilder } from './module_builder';
import type { HealthCheck } from './health/health_check';
import { HealthService } from './health/health_service';
import { MetricRegistry, MetricsRegistrar } from './metrics/metric_registry';
import { loggingMiddleware } from './logger/logging_middleware';
import { LogLevel } from './logger/logger';
import { bodyParserErrorHandler } from './body_parser_error_handler';
import { unhandledRequestErrorHandler } from './unhandled_request_error_handler';
import type { Counter, Gauge, Histogram } from './metrics/metric';
import { buildRuntimePlugins, operationalRoutePaths } from './official_plugins';
import { orderPlugins, PluginHostError, RuntimePluginHost, type Plugin } from './plugin';

export interface ModularApiOptions {
  /** Base path prefix for all module routes. Default: '/api' */
  basePath?: string;
  /** API title shown in Swagger UI. Default: 'API' */
  title?: string;
  /** API version string (e.g. '1.0.0'). Used in health check response. Default: '0.0.0' */
  version?: string;
  /**
   * Release identifier. Defaults to `version-debug`.
   * Override via `process.env.RELEASE_ID`.
   */
  releaseId?: string;
  /** Opt-in Prometheus metrics endpoint. Default: false */
  metricsEnabled?: boolean;
  /** Path for the metrics endpoint. Default: '/metrics' */
  metricsPath?: string;
  /** Routes excluded from instrumentation. Default: ['/metrics', '/health', '/docs'] */
  excludedMetricsRoutes?: string[];
  /**
   * Minimum log level for the structured JSON logger.
   * Default: LogLevel.info (emits emergency..info, suppresses debug).
   */
  logLevel?: LogLevel;
  /**
   * OpenAPI `servers` list. Each entry has a `url` and optional `description`.
   * When omitted, `serve()` generates `[{url: 'http://localhost:{port}'}]`.
   */
  servers?: Array<{ url: string; description?: string }>;
}

/**
 * Main entry point for modular_api.
 *
 * Dart equivalent:
 * ```dart
 * final api = ModularApi(basePath: '/api');
 * api.module('greetings', (m) => m.usecase('hello', SayHello.fromJson));
 * await api.serve(port: 8080);
 * ```
 *
 * TypeScript equivalent:
 * ```ts
 * const api = new ModularApi({ basePath: '/api' });
 * api.module('greetings', (m) => m.usecase('hello', SayHello.fromJson));
 * await api.serve({ port: 8080 });
 * ```
 *
 * Auto-mounted endpoints:
 *   GET /health  → 200/503 application/health+json (IETF draft)
 *   GET /docs    → Swagger UI
 */
export class ModularApi {
  private readonly app: Express;
  private readonly rootRouter: Router;
  private readonly basePath: string;
  private readonly title: string;
  private readonly version: string;
  private readonly middlewares: RequestHandler[] = [];
  private readonly healthService: HealthService;
  private readonly plugins: Plugin[] = [];

  // Metrics
  private readonly metricsEnabled: boolean;
  private readonly metricsPath: string;
  private readonly excludedMetricsRoutes: string[];
  private readonly metricRegistry?: MetricRegistry;
  private readonly _metricsRegistrar?: MetricsRegistrar;
  private readonly httpRequestsTotal?: Counter;
  private readonly httpRequestsInFlight?: Gauge;
  private readonly httpRequestDuration?: Histogram;

  // Logging
  private readonly logLevel: LogLevel;

  // OpenAPI
  private readonly servers?: Array<{ url: string; description?: string }>;

  /** Public accessor for custom-metric registration. Undefined when metrics are disabled. */
  get metrics(): MetricsRegistrar | undefined {
    return this._metricsRegistrar;
  }

  constructor(options: ModularApiOptions = {}) {
    this.basePath = options.basePath ?? '/api';
    this.title = options.title ?? 'Modular API';
    this.version = options.version ?? 'x.y.z';

    this.healthService = new HealthService({
      version: this.version,
      releaseId: options.releaseId,
    });

    // Metrics setup
    this.metricsEnabled = options.metricsEnabled ?? false;
    this.metricsPath = options.metricsPath ?? '/metrics';
    this.excludedMetricsRoutes = options.excludedMetricsRoutes ?? ['/metrics', '/health', '/docs'];

    // Logging
    this.logLevel = options.logLevel ?? LogLevel.info;

    // OpenAPI servers
    this.servers = options.servers;

    if (this.metricsEnabled) {
      this.metricRegistry = new MetricRegistry();
      this._metricsRegistrar = new MetricsRegistrar(this.metricRegistry);
      this.httpRequestsTotal = this.metricRegistry.createCounter({
        name: 'http_requests_total',
        help: 'Total number of HTTP requests.',
        labelNames: ['method', 'route', 'status_code'] as const,
      });
      this.httpRequestsInFlight = this.metricRegistry.createGauge({
        name: 'http_requests_in_flight',
        help: 'Number of HTTP requests currently being processed.',
      });
      this.httpRequestDuration = this.metricRegistry.createHistogram({
        name: 'http_request_duration_seconds',
        help: 'HTTP request duration in seconds.',
        labelNames: ['method', 'route', 'status_code'] as const,
      });
    }

    this.app = express();

    this.rootRouter = express.Router();
  }

  /**
   * Register a {@link HealthCheck} to be evaluated on `GET /health`.
   * Returns `this` for method chaining.
   *
   * ```ts
   * api.addHealthCheck(new DatabaseHealthCheck());
   * ```
   */
  addHealthCheck(check: HealthCheck): this {
    this.healthService.addHealthCheck(check);
    return this;
  }

  /**
   * Registers a group of use cases under a named module.
   * Returns `this` for method chaining.
   *
   * ```ts
   * api
   *   .module('users', (m) => {
   *     m.usecase('create', CreateUser.fromJson);
   *     m.usecase('list',   ListUsers.fromJson, { method: 'GET' });
   *   })
   *   .module('products', buildProductsModule);
   * ```
   */
  module(name: string, build: (m: ModuleBuilder) => void): this {
    const builder = new ModuleBuilder(this.basePath, name, this.rootRouter);
    build(builder);
    builder._mount();
    return this;
  }

  /**
   * Adds an Express middleware to the pipeline.
   * Applied in the order they are registered, before any module handler.
   * Returns `this` for method chaining.
   *
   * ```ts
   * api.use(cors()).use(myAuthMiddleware);
   * ```
   */
  use(middleware: RequestHandler): this {
    this.middlewares.push(middleware);
    return this;
  }

  plugin(plugin: Plugin): this {
    this.plugins.push(plugin);
    return this;
  }

  /**
   * Starts the Express server on the given port.
   *
   * Auto-mounts:
   *   GET /health → 200 "ok"
   *   GET /docs   → Swagger UI (built from registered use cases)
   *
   * @returns The Node.js http.Server instance
   */
  async serve(options: { port: number; host?: string }): Promise<import('http').Server> {
    const { port, host = '0.0.0.0' } = options;
    const operationalPaths = operationalRoutePaths(this.basePath, this.metricsEnabled ? this.metricsPath : undefined);
    const runtimePlugins = [
      ...this.plugins,
      ...buildRuntimePlugins({
        basePath: this.basePath,
        title: this.title,
        version: this.version,
        port,
        servers: this.servers,
        healthService: this.healthService,
        metrics:
          this.metricsEnabled &&
          this.metricRegistry &&
          this.httpRequestsTotal &&
          this.httpRequestsInFlight &&
          this.httpRequestDuration
            ? {
                path: this.metricsPath,
                registry: this.metricRegistry,
                requestsTotal: this.httpRequestsTotal,
                requestsInFlight: this.httpRequestsInFlight,
                requestDuration: this.httpRequestDuration,
                excludedRoutes: this.excludedMetricsRoutes,
              }
            : undefined,
      }),
    ];

    const seenPluginIds = new Set<string>();
    for (const plugin of runtimePlugins) {
      if (seenPluginIds.has(plugin.manifest.id)) {
        throw new PluginHostError(
          'PLUGIN_ID_CONFLICT',
          `Duplicate plugin id: ${plugin.manifest.id}`,
          plugin.manifest.id,
          plugin.manifest.id,
        );
      }
      seenPluginIds.add(plugin.manifest.id);
    }

    const orderedPlugins = orderPlugins(runtimePlugins);

    const pluginHost = new RuntimePluginHost({
      basePath: this.basePath,
      title: this.title,
      version: this.version,
    });

    try {
      for (const plugin of orderedPlugins) {
        pluginHost.beginPluginSetup(plugin.manifest.id);
        try {
          plugin.setup(pluginHost);
        } finally {
          pluginHost.endPluginSetup();
        }
        if (plugin.shutdown) {
          pluginHost.onShutdown(() => plugin.shutdown!());
        }
      }

      pluginHost.freeze();
      const validationResults = orderedPlugins.flatMap((plugin) => plugin.validate?.(pluginHost) ?? []);
      pluginHost.assertValid(validationResults);
    } catch (error) {
      await pluginHost.shutdown();
      throw error;
    }

    return await new Promise((resolve) => {
      // Logging middleware FIRST — trace_id + structured JSON logs.
      const excludedLogRoutes = [
        operationalPaths.healthPath,
        operationalPaths.docsPath,
        operationalPaths.openApiJsonPath,
        operationalPaths.openApiYamlPath,
        ...(operationalPaths.metricsPath ? [operationalPaths.metricsPath] : []),
      ];
      this.app.use(
        loggingMiddleware({
          logLevel: this.logLevel,
          serviceName: this.title,
          excludedRoutes: excludedLogRoutes,
        }),
      );

      // Body parsing AFTER loggingMiddleware — SyntaxErrors now have trace_id.
      this.app.use(express.json());
      this.app.use(bodyParserErrorHandler);

      pluginHost.applyMiddlewares('preRouting', this.app);

      // Register middlewares before routes
      for (const mw of this.middlewares) {
        this.app.use(mw);
      }

      pluginHost.applyMiddlewares('preHandler', this.app);
      pluginHost.applyMiddlewares('postHandler', this.app);

      pluginHost.applyRoutes(this.rootRouter);

      // Module use case routes.
      this.app.use(this.rootRouter);
      this.app.use(unhandledRequestErrorHandler);

      const server = this.app.listen(port, host, () => {
        const address = server.address();
        const resolvedPort = typeof address === 'object' && address ? address.port : port;
        console.log(`Docs  → http://localhost:${resolvedPort}${operationalPaths.docsPath}`);
        console.log(`Health → http://localhost:${resolvedPort}${operationalPaths.healthPath}`);
        console.log(`OpenAPI JSON → http://localhost:${resolvedPort}${operationalPaths.openApiJsonPath}`);
        console.log(`OpenAPI YAML → http://localhost:${resolvedPort}${operationalPaths.openApiYamlPath}`);
        if (operationalPaths.metricsPath) {
          console.log(`Metrics → http://localhost:${resolvedPort}${operationalPaths.metricsPath}`);
        }
        resolve(server);
      });

      server.on('close', () => {
        void pluginHost.shutdown();
      });
    });
  }
}
