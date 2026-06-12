import type { NextFunction, Request, RequestHandler, Response, Router } from 'express';
import { LOGGER_LOCALS_KEY } from './logger/logging_middleware';
import type { ModularLogger } from './logger/logger';
import { clearShortCircuitCandidate, setShortCircuitCandidate } from './request_pipeline_audit';
import { apiRegistry } from './registry';

export const HOST_API_VERSION = '0.1.0';

export type PluginRequirementType = 'plugin' | 'capability';
export type PluginRouteVisibility = 'operational' | 'transport' | 'custom';
export type MiddlewareSlot = 'preRouting' | 'preHandler' | 'postHandler';
export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

const ALLOWED_MIDDLEWARE_SLOTS = new Set<MiddlewareSlot>(['preRouting', 'preHandler', 'postHandler']);

export interface PluginRequirement {
  type: PluginRequirementType;
  id: string;
  version?: string;
}

export interface PluginManifest {
  id: string;
  displayName: string;
  version: string;
  hostApiVersion: string;
  requires?: PluginRequirement[];
  optional?: PluginRequirement[];
  contributes?: Record<string, unknown>;
}

export interface HostMetadata {
  basePath: string;
  title: string;
  version: string;
  hostApiVersion: string;
}

export interface PluginValidationResult {
  code: string;
  message: string;
  pluginId?: string;
  resourceId?: string;
  blocking?: boolean;
}

export interface Capability<T = unknown> {
  id: string;
  version: string;
  value: T;
}

export interface CapabilityHandle<T = unknown> {
  id: string;
  version: string;
  value: T;
}

export interface ModuleExtensionPoint {
  id: string;
  mode: 'single' | 'multi';
  description?: string;
}

export interface ModuleExtensionContribution {
  extensionPointId: string;
  moduleName: string;
  value: unknown;
}

export interface PluginRequestContext {
  requestId: string;
  logger?: ModularLogger;
  method: string;
  path: string;
  headers: Record<string, string | string[] | undefined>;
  query: Record<string, unknown>;
  body?: unknown;
  pathParams: Record<string, string>;
  capabilities(): ReadonlyMap<string, CapabilityHandle>;
}

export interface PluginResponse {
  status?: number;
  headers?: Record<string, string>;
  contentType?: string;
  body?: unknown;
}

export interface PluginRoute {
  id: string;
  method: HttpMethod;
  path: string;
  visibility: PluginRouteVisibility;
  /**
   * Optional standard OpenAPI Operation object (summary, parameters, requestBody,
   * responses — including binary content types). When present on a `custom` or
   * `transport` route, the official OpenApiPlugin merges it into the generated
   * spec so the route appears in /openapi.json and /docs (ADR-0003).
   */
  openapi?: Record<string, unknown>;
  handler(context: PluginRequestContext): PluginResponse | Promise<PluginResponse>;
}

export interface PluginMiddleware {
  id: string;
  slot: MiddlewareSlot;
  order?: number;
  handler: RequestHandler;
}

export interface RegisteredModuleView {
  name: string;
}

export interface RegisteredUseCaseView {
  module: string;
  command: string;
  method: string;
  path: string;
}

/** Read view of a plugin route already registered on the host (ADR-0003). */
export interface RegisteredPluginRouteView {
  pluginId?: string;
  id: string;
  method: HttpMethod;
  /** Absolute mounted path (basePath already joined). */
  path: string;
  visibility: PluginRouteVisibility;
  openapi?: Record<string, unknown>;
}

export interface PluginHost {
  metadata(): HostMetadata;
  modules(): RegisteredModuleView[];
  useCases(): RegisteredUseCaseView[];
  routes(): RegisteredPluginRouteView[];
  registerRoute(route: PluginRoute): void;
  registerMiddleware(middleware: PluginMiddleware): void;
  exposeCapability(capability: Capability): void;
  resolveCapability(id: string): CapabilityHandle | null;
  requireCapability(id: string): CapabilityHandle;
  declareModuleExtensionPoint(point: ModuleExtensionPoint): void;
  contributeModuleExtension(contribution: ModuleExtensionContribution): void;
  addStartupValidation(validation: PluginValidationResult): void;
  onShutdown(callback: () => void | Promise<void>): void;
}

export interface Plugin {
  manifest: PluginManifest;
  setup(host: PluginHost): void;
  validate?(host: PluginHost): PluginValidationResult[] | Promise<PluginValidationResult[]>;
  shutdown?(): void | Promise<void>;
}

export class PluginHostError extends Error {
  constructor(
    public readonly code: string,
    message: string,
    public readonly pluginId?: string,
    public readonly resourceId?: string,
  ) {
    super(message);
    this.name = 'PluginHostError';
  }
}

interface RuntimePluginRoute {
  finalPath: string;
  route: PluginRoute;
  pluginId?: string;
}

interface RuntimePluginMiddleware {
  definition: PluginMiddleware;
  sequence: number;
}

interface RuntimePluginHostOptions {
  basePath: string;
  title: string;
  version: string;
}

export class RuntimePluginHost implements PluginHost {
  private readonly metadataValue: HostMetadata;
  private readonly registeredRoutes: RuntimePluginRoute[] = [];
  private readonly middlewares: RuntimePluginMiddleware[] = [];
  private readonly capabilitiesMap = new Map<string, CapabilityHandle>();
  private readonly extensionPoints = new Map<string, ModuleExtensionPoint>();
  private readonly extensionValues = new Map<string, unknown[]>();
  private readonly startupValidations: PluginValidationResult[] = [];
  private readonly shutdownCallbacks: Array<() => void | Promise<void>> = [];
  private readonly routeKeys = new Set<string>();
  private middlewareSequence = 0;
  private activePluginId?: string;
  private frozen = false;

  constructor(options: RuntimePluginHostOptions) {
    this.metadataValue = {
      basePath: normalizeBasePath(options.basePath),
      title: options.title,
      version: options.version,
      hostApiVersion: HOST_API_VERSION,
    };
  }

  metadata(): HostMetadata {
    return { ...this.metadataValue };
  }

  modules(): RegisteredModuleView[] {
    return [...new Set(apiRegistry.routes.map((route) => route.module))].map((name) => ({ name }));
  }

  useCases(): RegisteredUseCaseView[] {
    return apiRegistry.routes.map((route) => ({
      module: route.module,
      command: route.command,
      method: route.method,
      path: route.path,
    }));
  }

  registerRoute(route: PluginRoute): void {
    this.assertMutable();

    const finalPath = joinPath(this.metadataValue.basePath, route.path);
    const key = `${route.method.toUpperCase()} ${finalPath}`;
    if (this.routeKeys.has(key)) {
      throw new PluginHostError('ROUTE_CONFLICT', `Route conflict for ${key}`, undefined, key);
    }

    this.routeKeys.add(key);
    this.registeredRoutes.push({ finalPath, route, pluginId: this.activePluginId });
  }

  routes(): RegisteredPluginRouteView[] {
    return this.registeredRoutes.map((registration) => ({
      pluginId: registration.pluginId,
      id: registration.route.id,
      method: registration.route.method,
      path: registration.finalPath,
      visibility: registration.route.visibility,
      openapi: registration.route.openapi,
    }));
  }

  registerMiddleware(middleware: PluginMiddleware): void {
    this.assertMutable();
    if (!ALLOWED_MIDDLEWARE_SLOTS.has(middleware.slot)) {
      throw new PluginHostError(
        'PLUGIN_VALIDATION_FAILED',
        `Unknown middleware slot: ${middleware.slot}`,
        undefined,
        middleware.id,
      );
    }

    this.middlewares.push({
      definition: {
        ...middleware,
        order: middleware.order ?? 0,
        handler: instrumentPluginMiddleware(
          { ...middleware, order: middleware.order ?? 0 },
          this.activePluginId,
        ),
      },
      sequence: this.middlewareSequence++,
    });
  }

  beginPluginSetup(pluginId: string): void {
    this.assertMutable();
    this.activePluginId = pluginId;
  }

  endPluginSetup(): void {
    this.activePluginId = undefined;
  }

  exposeCapability(capability: Capability): void {
    this.assertMutable();
    if (this.capabilitiesMap.has(capability.id)) {
      throw new PluginHostError(
        'CAPABILITY_CONFLICT',
        `Capability already exposed: ${capability.id}`,
        undefined,
        capability.id,
      );
    }

    this.capabilitiesMap.set(capability.id, { ...capability });
  }

  resolveCapability(id: string): CapabilityHandle | null {
    return this.capabilitiesMap.get(id) ?? null;
  }

  requireCapability(id: string): CapabilityHandle {
    const capability = this.resolveCapability(id);
    if (!capability) {
      throw new PluginHostError('CAPABILITY_REQUIRED_MISSING', `Missing capability: ${id}`, undefined, id);
    }

    return capability;
  }

  declareModuleExtensionPoint(point: ModuleExtensionPoint): void {
    this.assertMutable();
    if (this.extensionPoints.has(point.id)) {
      throw new PluginHostError(
        'MODULE_EXTENSION_POINT_CONFLICT',
        `Duplicate extension point: ${point.id}`,
        undefined,
        point.id,
      );
    }

    this.extensionPoints.set(point.id, point);
  }

  contributeModuleExtension(contribution: ModuleExtensionContribution): void {
    this.assertMutable();
    const point = this.extensionPoints.get(contribution.extensionPointId);
    if (!point) {
      throw new PluginHostError(
        'MODULE_EXTENSION_CONFLICT',
        `Unknown extension point: ${contribution.extensionPointId}`,
        undefined,
        contribution.extensionPointId,
      );
    }

    const key = `${contribution.extensionPointId}:${contribution.moduleName}`;
    const values = this.extensionValues.get(key) ?? [];
    if (point.mode === 'single' && values.length > 0) {
      throw new PluginHostError(
        'MODULE_EXTENSION_CONFLICT',
        `Duplicate contribution for single extension point ${key}`,
        undefined,
        key,
      );
    }

    values.push(contribution.value);
    this.extensionValues.set(key, values);
  }

  addStartupValidation(validation: PluginValidationResult): void {
    this.assertMutable();
    this.startupValidations.push(validation);
  }

  onShutdown(callback: () => void | Promise<void>): void {
    this.assertMutable();
    this.shutdownCallbacks.push(callback);
  }

  freeze(): void {
    this.frozen = true;
  }

  assertValid(additionalValidations: PluginValidationResult[] = []): void {
    const blocking = [...this.startupValidations, ...additionalValidations].find(
      (validation) => validation.blocking !== false,
    );
    if (blocking) {
      throw new PluginHostError(
        blocking.code,
        blocking.message,
        blocking.pluginId,
        blocking.resourceId,
      );
    }
  }

  applyRoutes(router: Router): void {
    for (const registration of this.registeredRoutes) {
      const method = registration.route.method.toLowerCase() as Lowercase<HttpMethod>;
      router[method](registration.finalPath, buildPluginRouteHandler(registration.route, this.capabilitiesMap));
    }
  }

  applyMiddlewares(slot: MiddlewareSlot, app: { use(handler: RequestHandler): void }): void {
    for (const middleware of this.middlewares
      .filter((candidate) => candidate.definition.slot === slot)
      .sort((left, right) => {
        const orderDelta = (left.definition.order ?? 0) - (right.definition.order ?? 0);
        return orderDelta !== 0 ? orderDelta : left.sequence - right.sequence;
      })) {
      app.use(middleware.definition.handler);
    }
  }

  async shutdown(): Promise<void> {
    for (const callback of [...this.shutdownCallbacks].reverse()) {
      await callback();
    }
  }

  private assertMutable(): void {
    if (this.frozen) {
      throw new PluginHostError('PLUGIN_VALIDATION_FAILED', 'Plugin host registration is frozen');
    }
  }
}

export function orderPlugins(plugins: readonly Plugin[]): Plugin[] {
  const pluginsById = new Map<string, Plugin>();
  for (const plugin of plugins) {
    pluginsById.set(plugin.manifest.id, plugin);
  }

  const visitState = new Map<string, 'visiting' | 'visited'>();
  const ordered: Plugin[] = [];

  const visit = (plugin: Plugin): void => {
    const pluginId = plugin.manifest.id;
    const state = visitState.get(pluginId);
    if (state === 'visited') {
      return;
    }

    if (state === 'visiting') {
      throw new PluginHostError(
        'PLUGIN_DEPENDENCY_CYCLE',
        `Plugin dependency cycle detected at ${pluginId}`,
        pluginId,
        pluginId,
      );
    }

    visitState.set(pluginId, 'visiting');
    for (const requirement of plugin.manifest.requires ?? []) {
      if (requirement.type !== 'plugin') {
        continue;
      }

      const dependency = pluginsById.get(requirement.id);
      if (!dependency) {
        throw new PluginHostError(
          'PLUGIN_DEPENDENCY_MISSING',
          `Missing required plugin dependency ${requirement.id} for ${pluginId}`,
          pluginId,
          requirement.id,
        );
      }

      visit(dependency);
    }

    visitState.set(pluginId, 'visited');
    ordered.push(plugin);
  };

  for (const plugin of plugins) {
    visit(plugin);
  }

  return ordered;
}

function buildPluginRouteHandler(
  route: PluginRoute,
  capabilities: ReadonlyMap<string, CapabilityHandle>,
): RequestHandler {
  return async (req: Request, res: Response, next: NextFunction) => {
    try {
      const logger = res.locals[LOGGER_LOCALS_KEY] as ModularLogger | undefined;
      const response = await route.handler({
        requestId: readRequestId(req, res),
        logger,
        method: req.method,
        path: req.path,
        headers: req.headers,
        query: req.query,
        body: req.body,
        pathParams: Object.fromEntries(
          Object.entries(req.params).map(([key, value]) => [
            key,
            Array.isArray(value) ? (value[0] ?? '') : value,
          ]),
        ),
        capabilities: () => capabilities,
      });

      if (response.headers) {
        for (const [name, value] of Object.entries(response.headers)) {
          res.setHeader(name, value);
        }
      }

      if (response.contentType) {
        res.setHeader('Content-Type', response.contentType);
      }

      const status = response.status ?? 200;
      const body = response.body;
      if (body === undefined) {
        res.sendStatus(status);
        return;
      }

      if (typeof body === 'string' || Buffer.isBuffer(body)) {
        res.status(status).send(body);
        return;
      }

      res.status(status).json(body);
    } catch (error) {
      next(error);
    }
  };
}

function readRequestId(req: Request, res: Response): string {
  const fromHeader = req.header('X-Request-ID');
  if (fromHeader) {
    return fromHeader;
  }

  const fromLogger = res.locals[LOGGER_LOCALS_KEY] as ModularLogger | undefined;
  return fromLogger?.traceId ?? 'unknown';
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
    throw new PluginHostError('PLUGIN_VALIDATION_FAILED', 'Plugin route path cannot be empty');
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

function instrumentPluginMiddleware(
  middleware: PluginMiddleware,
  pluginId?: string,
): RequestHandler {
  return (req: Request, res: Response, next: NextFunction): void => {
    setShortCircuitCandidate(res, {
      pluginId: pluginId ?? 'unknown',
      middlewareId: middleware.id,
      slot: middleware.slot,
    });

    const observedNext: NextFunction = (error?: unknown): void => {
      clearShortCircuitCandidate(res, middleware.id);
      next(error);
    };

    try {
      const result = middleware.handler(req, res, observedNext);
      if (result && typeof (result as PromiseLike<unknown>).then === 'function') {
        void Promise.resolve(result).catch((error: unknown) => {
          clearShortCircuitCandidate(res, middleware.id);
          next(error);
        });
      }
    } catch (error) {
      clearShortCircuitCandidate(res, middleware.id);
      next(error);
    }
  };
}