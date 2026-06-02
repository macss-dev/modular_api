# Plugin Host Contract Draft

**Status:** Draft  
**Date:** 2026-06-01  
**Applies to:** Dart, TypeScript, Python, and future SDKs

---

## 1. Purpose

This document defines a first public draft of the plugin host contract for
Modular API.

Its goal is to turn the current architectural direction into a language-agnostic
contract that can be implemented consistently across SDKs.

This is a **host contract draft**, not an implementation guide. It specifies
what the core MUST expose to plugins and what plugins MAY contribute through the
public extension surface.

---

## 2. Design Goals

The contract is designed to satisfy the following goals:

- keep the core limited to modules, use cases, request lifecycle, middleware,
  request-scoped logging, and the plugin host
- let official plugins and third-party plugins use the same public contract
- support both global plugins and module-scoped extensions
- enable plugin collaboration through explicit capabilities rather than hidden
  core fields
- make startup validation, ordering, and conflict detection deterministic
- stay small enough to implement consistently across Dart, TypeScript, and
  Python without framework-specific leakage

---

## 3. Non-Goals

The following are explicitly out of scope for this draft:

- a GraphQL implementation
- transport adapters beyond HTTP
- sandboxing or out-of-process plugin isolation
- plugin packaging and marketplace distribution
- plugin-specific configuration UX

---

## 4. Normative Language

The keywords **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY**
follow RFC 2119 semantics.

---

## 5. Contract Overview

The contract has two layers:

1. A **declarative layer** that identifies the plugin, expresses compatibility,
   declares dependencies, and describes its public contribution surface.
2. An **imperative layer** that lets the plugin register routes, middleware,
   capabilities, startup validations, shutdown hooks, and module-scoped
   extensions.

The host owns lifecycle orchestration. Plugins do not self-activate outside the
host lifecycle.

---

## 6. Core Concepts

### 6.1 Plugin Manifest

Every plugin MUST expose a manifest.

```
PluginManifest
├── id: string
├── displayName: string
├── version: string
├── hostApiVersion: string
├── requires?: PluginRequirement[]
├── optional?: PluginRequirement[]
└── contributes?: PluginContributionSummary
```

#### Rules

- `id` MUST be unique within the process.
- `id` SHOULD use a stable, lowercase, URL-safe format.
- `version` MUST follow SemVer.
- `hostApiVersion` MUST express the supported host contract version range.
- `requires` MAY declare required plugins and required capabilities.
- `optional` MAY declare soft dependencies that do not block startup.
- `contributes` is descriptive metadata only. It MUST NOT replace runtime
  registration.

#### Recommended `id` format

The recommended plugin identifier format is:

```
<scope>.<name>
```

Examples:

- `modular.health`
- `modular.metrics`
- `acme.graphql`

### 6.2 Plugin Requirement

```
PluginRequirement
├── type: "plugin" | "capability"
├── id: string
└── version?: string
```

#### Rules

- A required plugin dependency MUST exist before startup completes.
- A required capability MUST be resolvable before startup completes.
- Version matching MUST happen during startup validation, not lazily at first
  use.

### 6.3 Plugin Interface

Every plugin MUST implement the following public contract.

```
Plugin
├── manifest: PluginManifest
├── setup(host) -> void
├── validate?(host) -> PluginValidationResult[]
└── shutdown?(host) -> void | Promise<void>
```

#### Rules

- `setup(host)` MUST be the only phase in which a plugin registers routes,
  middleware, capabilities, and module extension points.
- `validate(host)` runs after all plugins finished setup.
- `shutdown(host)` runs during host shutdown in reverse startup order.
- Plugins MUST NOT mutate the host after startup is frozen.

### 6.4 Plugin Host

The host is the only public surface through which plugins can extend the core.

```
PluginHost
├── metadata() -> HostMetadata
├── modules() -> RegisteredModuleView[]
├── useCases() -> RegisteredUseCaseView[]
├── registerRoute(route) -> void
├── registerMiddleware(middleware) -> void
├── exposeCapability(capability) -> void
├── resolveCapability(id) -> CapabilityHandle | null
├── requireCapability(id) -> CapabilityHandle
├── declareModuleExtensionPoint(point) -> void
├── contributeModuleExtension(contribution) -> void
├── addStartupValidation(validation) -> void
└── onShutdown(callback) -> void
```

#### Rules

- The host MUST expose read-only metadata about the API.
- The host MUST expose read-only views of the registered modules and use cases.
- The host MUST NOT expose mutable core internals.
- The host MUST freeze further registration once startup validation begins.

### 6.5 Host Metadata

```
HostMetadata
├── basePath: string
├── title: string
├── version: string
└── hostApiVersion: string
```

#### Rules

- `basePath` is the shared API mount path for the current instance.
- `basePath` defaults to `/`.
- `title` and `version` come from the main `ModularApi` configuration.
- `hostApiVersion` is the version of this plugin host contract.

---

## 7. Route Contributions

Plugins MAY register routes for the current API instance.

```
PluginRoute
├── id: string
├── method: HttpMethod
├── path: string
├── visibility: "operational" | "transport" | "custom"
└── handler(context) -> PluginResponse
```

### Rules

- Route `id` MUST be unique within the plugin.
- The final route MUST be the normalized concatenation of the host
  `basePath` and the plugin relative `path`.
- All public routes for the API instance MUST resolve under the same host
  `basePath`.
- Plugins MUST NOT bypass the host `basePath` or register root-level routes
  outside that shared mount path.
- If `basePath` is `/`, the normalized final route is rooted at `/`.
- Operational endpoints such as `/health`, `/metrics`, `/docs`,
  `/openapi.json`, and `/openapi.yaml` are declared by plugins as relative
  paths and resolve under that shared mount path.
- Business transports such as a future GraphQL transport use that same API
  namespace.
- The host MUST reject duplicate method and final-path pairs at startup.

### Path normalization

- Leading slashes MUST be normalized.
- Duplicate slashes MUST be collapsed.
- Empty paths are invalid.

---

## 8. Middleware Contributions

Plugins MAY register middleware only in predefined public slots.

```
PluginMiddleware
├── id: string
├── slot: MiddlewareSlot
├── order?: int
└── handler(context, next) -> Response
```

### 8.1 Public Middleware Slots

The first draft defines exactly three stable public slots:

| Slot | Position | Intended use |
| --- | --- | --- |
| `preRouting` | After core logging, before route resolution | metrics, coarse request normalization, request guards |
| `preHandler` | After route resolution, before plugin route handler or use case handler | auth, authorization, request enrichment |
| `postHandler` | After handler execution, before response write | response decoration, headers, auditing |

### Rules

- Plugins MUST register middleware only in one of the public slots.
- Unknown slot names MUST raise a startup error.
- `order` defaults to `0`.
- Lower `order` values run earlier within the same slot.
- Registration order breaks ties.
- Core logging remains outside plugin control and always runs first.
- Plugins MUST NOT register middleware that bypasses the core use case
  lifecycle.

---

## 9. Capability Registry

Capabilities are the primary collaboration mechanism between plugins.

```
Capability
├── id: string
├── version: string
└── value: object
```

### Recommended capability identifier format

```
<plugin-id>/<capability-name>/v<major>
```

Examples:

- `modular.metrics/registry/v1`
- `modular.openapi/spec/v1`
- `modular.health/service/v1`

### Rules

- Capability ids MUST be globally unique.
- Capability ids SHOULD include a version suffix.
- Exposing the same capability id more than once is a startup error unless the
  host later introduces an explicit multi-provider capability type.
- Plugins SHOULD depend on capabilities rather than on concrete plugin ids when
  the collaboration target is behavioral rather than organizational.
- Capability resolution MUST be read-only to consumers.

---

## 10. Module-Scoped Extensions

The host MUST support module-scoped extension data without adding plugin-
specific fields to the core module API.

### 10.1 Module Extension Point

```
ModuleExtensionPoint
├── id: string
├── mode: "single" | "multi"
└── description?: string
```

### 10.2 Module Extension Contribution

```
ModuleExtensionContribution
├── extensionPointId: string
├── moduleName: string
└── value: object
```

### Rules

- Extension point ids SHOULD use the same versioned format as capabilities.
- The core MUST store extension contributions opaquely.
- The core MUST NOT interpret plugin-specific extension payloads.
- If an extension point is `single`, multiple contributions to the same module
  and extension point are a startup error.
- If an extension point is `multi`, contributions are stored in deterministic
  order.
- The host MUST make module extension data available read-only to plugins that
  know how to interpret it.

### Rationale

This mechanism is intended to support future transports such as GraphQL without
adding GraphQL-specific properties to `module()` or `usecase()` registration.

---

## 11. Lifecycle

The host lifecycle is deterministic and host-owned.

### 11.1 Registration Phase

- The application registers modules.
- The application registers plugin instances through `api.plugin(plugin)`.
- No plugin logic runs yet beyond manifest capture.

### 11.2 Setup Phase

- The host validates manifest shape and plugin id uniqueness.
- The host resolves plugin dependency order.
- The host calls `setup(host)` once for each plugin.
- Plugins register routes, middleware, capabilities, module extension points,
  module extensions, startup validations, and shutdown hooks.

### 11.3 Validation Phase

- The host freezes registration.
- The host executes built-in validation checks.
- The host executes plugin-provided `validate(host)` hooks.
- If any blocking validation fails, startup aborts.

### 11.4 Runtime Phase

- The server starts serving requests.
- The host exposes only read-only inspection and capability resolution to
  plugins.
- No new registrations are allowed.

### 11.5 Shutdown Phase

- The host runs plugin shutdown callbacks in reverse startup order.
- The host then releases framework-specific resources.

---

## 12. Ordering Model

This draft intentionally keeps ordering rules small.

### Rules

- Plugin setup order is the topologically sorted dependency order.
- Registration order breaks ties when no dependency edge exists.
- Middleware order is resolved by `(slot, order, plugin setup order)`.
- Shutdown runs in reverse plugin setup order.
- Route handlers are not priority-based. Route conflicts fail startup instead.
- Capability exposure is not ordered. Duplicate providers fail startup.

### Why this model

The host SHOULD avoid a large matrix of priorities, wrappers, and per-hook
ordering controls in the first contract. The initial goal is predictability,
not maximal flexibility.

---

## 13. Startup Validation and Standard Errors

The host MUST standardize startup failures so that all SDKs report the same
classes of configuration problems.

### 13.1 Standard Error Codes

| Code | Meaning |
| --- | --- |
| `PLUGIN_ID_CONFLICT` | Two plugins use the same id |
| `PLUGIN_HOST_VERSION_UNSUPPORTED` | Plugin hostApiVersion does not match the runtime |
| `PLUGIN_DEPENDENCY_MISSING` | A required plugin dependency is absent |
| `PLUGIN_DEPENDENCY_CYCLE` | Plugin dependency graph is cyclic |
| `CAPABILITY_REQUIRED_MISSING` | A required capability is not exposed |
| `CAPABILITY_CONFLICT` | More than one plugin exposes the same capability id |
| `ROUTE_CONFLICT` | Two handlers resolve to the same method and final path |
| `MIDDLEWARE_SLOT_UNKNOWN` | A plugin uses a non-public middleware slot |
| `MODULE_EXTENSION_POINT_CONFLICT` | Duplicate declaration of the same extension point id |
| `MODULE_EXTENSION_CONFLICT` | Invalid duplicate contribution to a single-valued extension point |
| `PLUGIN_VALIDATION_FAILED` | A plugin's explicit startup validation failed |

### Rules

- These error codes MUST be preserved across language implementations.
- SDKs MAY wrap them in language-native exception types.
- The error payload SHOULD include `pluginId`, `resourceId`, and a human-
  readable message when applicable.

---

## 14. Request Context Available to Plugin Handlers and Middleware

Plugins do not receive the mutable core internals. They receive a request-scoped
context.

```
PluginRequestContext
├── requestId: string
├── logger: ModularLogger
├── method: string
├── path: string
├── headers: Map
├── query: Map
├── body?: object
├── pathParams: Map
└── capabilities() -> read-only resolver view
```

### Rules

- `logger` MUST be the same request-scoped logger used by core use cases.
- The context MAY expose framework-adapted request data, but the public shape
  MUST remain semantically equivalent across SDKs.
- Plugins MUST NOT receive writable access to the module or use case registry
  through the request context.

---

## 15. Official Plugin Mapping in This Draft

The first official plugins map cleanly onto this contract:

### `HealthPlugin`

- registers `/health` under the shared `basePath`, resolving to
  `/{basePath}/health`
- exposes `modular.health/service/v1`

### `MetricsPlugin`

- registers `/metrics` under the shared `basePath`, resolving to
  `/{basePath}/metrics`
- registers middleware in `preRouting`
- exposes `modular.metrics/registry/v1`

### `OpenApiPlugin`

- registers `/openapi.json` and `/openapi.yaml` under the shared `basePath`
- exposes `modular.openapi/spec/v1`

### `DocsPlugin`

- registers `/docs` under the shared `basePath`, resolving to
  `/{basePath}/docs`
- requires `modular.openapi/spec/v1`

This is intentional. Official plugins are not special cases in the host.

---

## 16. Minimal Pseudocode Example

```text
api = ModularApi(basePath="/api", title="Modular API", version="0.5.0")

api.module("greetings", buildGreetings)

api.plugin(MetricsPlugin())
api.plugin(OpenApiPlugin())
api.plugin(DocsPlugin())

api.serve()
```

```text
class DocsPlugin implements Plugin:
  manifest = {
    id: "modular.docs",
    displayName: "Docs Plugin",
    version: "0.1.0",
    hostApiVersion: ">=0.1.0 <0.2.0",
    requires: [
      { type: "capability", id: "modular.openapi/spec/v1" }
    ]
  }

  setup(host):
    spec = host.requireCapability("modular.openapi/spec/v1")
    host.registerRoute({
      id: "docs-ui",
      method: "GET",
      path: "/docs",
      visibility: "operational",
      handler: renderDocs(spec)
    })
```

---

## 17. Decisions This Draft Intentionally Makes Now

This draft resolves four open questions from the previous analysis:

1. The contract should live as a public SDK-level surface first. Package splits
   can happen later if needed.
2. The first stable middleware slots are `preRouting`, `preHandler`, and
   `postHandler`.
3. The module-scoped extension API is capability-like and opaque to the core.
4. Startup errors should be standardized with explicit cross-language codes.

---

## 18. Remaining Open Questions

The following questions still need design work before implementation starts:

1. Should plugin manifests remain runtime objects only, or should each SDK also
   support a serializable manifest export for tooling?
2. Does the first implementation need a multi-provider capability type, or is
   single-provider enough for the first milestone?
3. Should plugin routes be allowed to opt out of specific middleware slots, or
   should that remain host policy only?
4. Do module extension contributions need schema validation in the first
   milestone, or can they remain opaque values only?

---

## 19. Immediate Next Step

Implement a minimal host in each SDK that supports:

- plugin manifests
- `setup`, `validate`, and `shutdown`
- route registration
- middleware registration in the three public slots
- capability exposure and resolution
- module extension points and contributions
- standardized startup errors

Once that slice exists, migrate Health, Metrics, OpenAPI, and Docs to it before
any GraphQL work begins.