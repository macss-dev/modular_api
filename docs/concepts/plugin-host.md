# Plugin Host

The plugin host is the public extension contract of modular_api. It is the same
conceptual model in TypeScript, Dart, and Python, and the official plugins
(health, metrics, OpenAPI, docs) use exactly the same public contract as
third-party plugins.

Facts on this page marked "(source-verified)" were confirmed against
`code/ts/modular_api/src/core/plugin.ts` and
`code/ts/modular_api/src/core/official_plugins.ts` on the 0.5.0 line.

## What a plugin can do

- `ModularApi.plugin(...)` registers a plugin instance; nothing runs at
  registration time.
- A plugin declares a `manifest` with identity (`id`), `displayName`, `version`,
  host compatibility (`hostApiVersion`), and optional dependencies
  (`requires` / `optional`).
- During `setup(host)` a plugin can register routes, global middlewares,
  capabilities, module-extension data, startup validations, and shutdown hooks.
- `host.metadata()` exposes the resolved `basePath`, API title, API version, and
  host API version.

## Lifecycle contract

Startup is host-owned and deterministic:

1. Plugins are registered in application code with `api.plugin(...)`.
2. At startup, the host orders plugins by declared plugin dependencies
   (topological sort; a dependency cycle aborts startup with
   `PLUGIN_DEPENDENCY_CYCLE`, a missing dependency with
   `PLUGIN_DEPENDENCY_MISSING`).
3. `setup(host)` runs once per plugin. **User plugins run `setup()` before the
   official plugins** (source-verified: `serve()` builds the runtime list as
   `[...userPlugins, ...officialPlugins]`). This matters: official plugins can see
   what user plugins registered (e.g. the OpenApiPlugin merges user plugin routes
   into the spec), but a user plugin cannot consume capabilities exposed by
   official plugins during its own `setup()`.
4. Host registration freezes before validation begins. Any registration attempt
   after the freeze throws.
5. `validate(host)` results and host-added startup validations are evaluated.
   A result with `blocking: true` — or with `blocking` omitted, since blocking
   defaults to true (source-verified: `assertValid` treats every result where
   `blocking !== false` as blocking) — throws `PluginHostError` and **aborts
   `serve()`**. This is the supported fail-fast mechanism for missing
   environment variables or misconfiguration: validate the environment in
   `validate()` and the process never starts half-configured.
6. If startup fails after some plugins already ran `setup()`, registered shutdown
   hooks still run in reverse setup order before the error is rethrown.
7. On normal shutdown, shutdown hooks run in reverse setup order.

## Routes

- Plugin routes are declared with relative paths (`/hello-plugin`).
- Routes are **always mounted under the configured `basePath`**
  (source-verified: `registerRoute` computes `joinPath(basePath, route.path)`).
  A plugin cannot opt out and mount at the server root.
- Empty relative paths are rejected; duplicate `(method, finalPath)` pairs are
  rejected before startup completes (`ROUTE_CONFLICT`).
- Route visibility is one of `operational`, `transport`, or `custom`.

### Binary responses

`PluginResponse` supports binary bodies (source-verified in the route handler):

```ts
host.registerRoute({
  id: 'photo.original',
  method: 'GET',
  path: '/photos/:id/original',
  visibility: 'transport',
  handler: async (ctx) => ({
    status: 200,
    contentType: 'image/jpeg',
    body: await repository.readBytes(ctx.pathParams.id), // Buffer
  }),
});
```

The dispatcher sends `string` and `Buffer` bodies as-is (with the declared
`contentType`), serializes anything else as JSON, and answers with the bare status
code when `body` is undefined. This is the sanctioned mechanism for serving
binaries — the JSON-only use case core deliberately does not cover them.

### Routes in OpenAPI and metrics (new in 0.5.0, ADR-0003)

`PluginRoute` accepts an optional `openapi` field holding a **standard OpenAPI
Operation object** (summary, parameters, requestBody, responses — including binary
content types such as `image/jpeg` with `schema: { type: string, format: binary }`).
No bespoke DSL: you write exactly what you would write by hand.

- Routes with visibility `custom` or `transport` and an `openapi` operation are
  merged into the generated spec and appear in `/openapi.json`, `/openapi.yaml`,
  and `/docs` (source-verified: `mergePluginRoutesIntoSpec`).
- `operational` routes are never documented by default — health/metrics/docs do
  not belong to the business contract.
- The metrics middleware now recognizes registered plugin route paths, so plugin
  routes receive their **real route label** in `http_requests_total` and the
  duration histogram instead of `UNMATCHED` (source-verified: the MetricsPlugin
  builds `registeredPaths` from the use case registry plus `host.routes()`).

```ts
host.registerRoute({
  id: 'photo.original',
  method: 'GET',
  path: '/photos/:id/original',
  visibility: 'transport',
  openapi: {
    summary: 'Download the original photo',
    parameters: [{ name: 'id', in: 'path', required: true, schema: { type: 'string' } }],
    responses: {
      '200': {
        description: 'JPEG bytes',
        content: { 'image/jpeg': { schema: { type: 'string', format: 'binary' } } },
      },
    },
  },
  handler: /* ... */,
});
```

### Inspecting registered routes

`PluginHost.routes()` (new in 0.5.0) returns the read view of registered plugin
routes — analogous to the existing `useCases()` view. Each entry exposes the
owning `pluginId`, route `id`, `method`, the **absolute mounted path** (basePath
already joined), `visibility`, and the `openapi` operation when present
(source-verified: `RegisteredPluginRouteView`).

## Middleware

Plugins register middleware in one of three slots: `preRouting`, `preHandler`,
`postHandler` (see [request-lifecycle.md](request-lifecycle.md) for the exact
pipeline positions).

**Plugin middlewares are GLOBAL** (source-verified: `applyMiddlewares` mounts each
handler with `app.use(handler)` — no path argument). There is no per-route
middleware. If a middleware should only affect certain requests, the plugin is
responsible for self-filtering on `req.path` / `req.method` and calling `next()`
for everything else.

Ordering inside a slot: lower `order` first, plugin setup order breaks ties.
Middleware handlers use the native continuation semantics of the host framework —
call `next()` (or the inner handler) when the normal lifecycle should continue.
Deliberate early termination is allowed; the host records attributable
short-circuit metadata in the completed-request log and normalizes uncaught
plugin-pipeline exceptions to structured JSON 500 responses.

## Capabilities and module extensions

- `exposeCapability` / `resolveCapability` / `requireCapability` share typed
  values between plugins (e.g. the official OpenAPI plugin exposes
  `modular_api.openapi.spec`). Duplicate capability ids are rejected.
- `declareModuleExtensionPoint` / `contributeModuleExtension` let plugins attach
  per-module data, with `single` or `multi` contribution modes.

Because user plugins set up first, capabilities exposed by official plugins are not
available during a user plugin's `setup()`. If you need the final OpenAPI spec,
prefer the route-level `openapi` field (it composes; the capability mutation
approach was explicitly discarded in ADR-0003).

## Minimal plugin example (TypeScript)

```ts
import {
  ModularApi,
  type Plugin,
  type PluginHost,
  type PluginManifest,
} from '@macss/modular-api';

class HelloPlugin implements Plugin {
  readonly manifest: PluginManifest = {
    id: 'acme.hello',
    displayName: 'Hello Plugin',
    version: '0.1.0',
    hostApiVersion: '>=0.1.0 <0.2.0',
  };

  setup(host: PluginHost): void {
    host.registerRoute({
      id: 'hello-plugin',
      method: 'GET',
      path: '/hello-plugin',
      visibility: 'custom',
      handler: () => ({
        status: 200,
        body: { ok: true, basePath: host.metadata().basePath },
      }),
    });
  }

  validate(host: PluginHost) {
    if (!process.env.ACME_API_KEY) {
      return [
        {
          code: 'ACME_ENV_MISSING',
          message: 'ACME_API_KEY is required',
          blocking: true, // aborts serve()
        },
      ];
    }
    return [];
  }
}

const api = new ModularApi({ basePath: '/api' }).plugin(new HelloPlugin());
await api.serve({ port: 8080 });
```

### Dart parity notes

Same model with explicit marker interfaces: `Plugin`, `ValidatingPlugin.validate(host)`,
`ShutdownAwarePlugin.shutdown()`. Routes are `PluginRoute(...)` objects whose
handlers return Shelf `Response` values.

### Python parity notes

Same model with snake_case members (`display_name`, `host_api_version`,
`register_route`, `base_path`) and `async shutdown()`. Setup runs during
`api.build()` rather than `serve()`.

## Current limits

- Per-route plugin middleware does not exist (global only, self-filter).
- Broader startup-validation coverage is still being expanded beyond
  dependency-missing and dependency-cycle failures.
- A public metrics capability (for plugins to register custom metrics through the
  host) remains an open follow-up; the metrics endpoint itself is hosted by the
  official plugin.

## Related

- [Request lifecycle](request-lifecycle.md)
- [Operational plugins](operational-plugins.md)
- [ADR-0003 — Plugin routes are first-class in OpenAPI and metrics](../adr/0003-plugin-routes-first-class-in-openapi-and-metrics.md)
