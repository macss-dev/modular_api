# modular_api - Product Roadmap

This roadmap is intentionally focused on the API product itself: the core runtime, the plugin ecosystem, and the next official capabilities. It excludes unrelated future initiatives that are not part of the current direction.

---

## Versioning Philosophy

Every release must be coherent on its own.

- **Major** - breaking changes to the core contract or plugin contract
- **Minor** - new capabilities, new plugins, new public APIs
- **Patch** - bug fixes, documentation, and performance improvements

---

## Current State - v0.4.7

`modular_api` currently provides:

- Official SDKs in Dart, TypeScript, and Python
- A modular REST API model based on modules, DTOs, and use cases
- A public plugin host in all three SDKs
- Deterministic plugin lifecycle orchestration: setup, validation, freeze, and shutdown
- Request-scoped structured logging
- Three public middleware slots with deterministic runtime ordering: `preRouting`, `preHandler`, and `postHandler`
- Host-owned plugin-pipeline guardrails: attributable middleware short-circuits in request logs and structured JSON `500` responses for uncaught plugin-pipeline failures
- Official `HealthPlugin`, `OpenApiPlugin`, and `DocsPlugin` mounted under the shared `basePath`
- Plugin-hosted health checks and Prometheus metrics endpoints under the shared `basePath`
- Cross-language parity tests across the three SDKs

The main remaining gaps for the v0.5.0 milestone are broader startup-validation
coverage, the public metrics capability surface, and the final reference-plugin
and migration docs.

---

## v0.5.0 - Plugin Infrastructure

> The immediate goal is to formalize the plugin ecosystem and reduce the core to its essential responsibilities.

### Core Scope After the Refactor

The core should know only about:

- Modules
- Use cases and DTO contracts
- Common request lifecycle
- HTTP middleware pipeline
- Request-scoped logger context
- Plugin host

### Deliverables

- [x] Add a public `.plugin()` API to `ModularApi`
- [x] Define a public plugin contract in all three SDKs
- [x] Define startup validation for plugin names, route collisions, and capability dependencies
- [x] Define middleware slots that plugins can target with deterministic ordering
- [x] Tighten middleware guardrails so plugins cannot bypass the approved core pipeline unintentionally
- [x] Define a module-extension mechanism so plugins can attach module-scoped metadata without polluting the core API
- [x] Define a capability registry so plugins can expose and consume shared services
- [x] Document how to build custom plugins for Dart, TypeScript, and Python
- [ ] Provide a minimal reference plugin built only on the public contract

### Official Plugins in This Stage

- [x] `HealthPlugin` - owns `/{basePath}/health` and health-check registration
- [ ] `MetricsPlugin` - owns `/{basePath}/metrics`, the HTTP metrics middleware, and the public metrics registrar
- [x] `OpenApiPlugin` - owns `/{basePath}/openapi.json` and `/{basePath}/openapi.yaml`
- [x] `DocsPlugin` - owns `/{basePath}/docs` and consumes the OpenAPI capability instead of rebuilding the spec itself

### Endpoint Policy

- Every public endpoint resolves under the shared `basePath`.
- `/{basePath}/docs` remains the canonical human-facing documentation endpoint.
- `/{basePath}/openapi.json` and `/{basePath}/openapi.yaml` remain the raw machine-facing contract endpoints.
- `/{basePath}/health` and `/{basePath}/metrics` remain the canonical operational endpoints.

### Exit Criterion

A developer outside the project can build and mount a custom plugin using the same public contract used by the official plugins.

---

## v0.6.0 - Optional GraphQL Plugin

> GraphQL is future work. It matters now only as a design constraint for the plugin system.

### Goals

- [ ] Implement an official GraphQL plugin for queries
- [ ] Keep commands as REST use cases provided by the core module system
- [ ] Make CQRS an optional architecture profile activated by the GraphQL plugin
- [ ] Preserve REST-only APIs as a first-class supported mode
- [ ] Reuse the same logging context, middleware pipeline, and plugin host introduced in v0.5.0

### Exit Criterion

An API can run in either of these modes without changing the core model:

- REST-only
- REST commands + GraphQL queries through the official plugin

---

## v0.7.0 - Foundation Hardening

> After the plugin host exists, the focus shifts to stability, docs, and maintainability.

- [ ] Migrate the generated spec to OpenAPI 3.1 when compatibility work is ready
- [ ] Strengthen CI/CD for all three SDKs
- [ ] Add plugin compatibility tests across languages
- [ ] Write contribution guides and style guides per language
- [ ] Document migration guidance for users moving from core-managed global endpoints to plugins

### Exit Criterion

A new contributor can read the docs, create a module, enable the official plugins they want, and run the same conceptual API in Dart, TypeScript, and Python.

---

## Invariants

These points do not change across milestones:

1. The core stays minimal.
2. Official plugins must use the same public contract as third-party plugins.
3. REST-only APIs remain valid with or without optional plugins.
4. `/{basePath}/docs` stays the canonical interactive documentation endpoint.
5. CQRS is optional and only becomes active when the future GraphQL plugin is enabled.

---

## Summary Timeline

```
v0.4.7  Current state: core + directly mounted global capabilities
v0.5.0  Plugin infrastructure + official global plugins
v0.6.0  Optional GraphQL plugin and optional CQRS profile
v0.7.0  Foundation hardening and contributor experience
```