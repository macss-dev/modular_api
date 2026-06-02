# Plugin Architecture Analysis

**Status:** Draft  
**Date:** 2026-06-01

---

## Purpose

This document captures the current design decisions for the plugin refactor.
Its goal is to make the next implementation stage explicit before code changes
begin in the SDKs.

The scope of this stage is limited to formalizing the plugin system.
GraphQL matters only as a future design constraint. It is not part of the
current implementation work.

---

## Agreed Direction

### 1. Core Responsibilities

After the refactor, the core should know only about:

- module registration
- use case and DTO contracts
- common request lifecycle
- HTTP middleware pipeline
- request-scoped logger context
- plugin host

Everything else should be modeled as a plugin.

### 2. Official Plugins in the First Stage

The first official plugins are:

- `HealthPlugin`
- `MetricsPlugin`
- `OpenApiPlugin`
- `DocsPlugin`

These plugins already exist conceptually in the product. The refactor is about
making them use the public plugin model instead of special-case core code.

### 3. Route Policy

The API instance has one shared public mount path, `basePath`, which defaults
to `/`. All public routes, including module use case routes and plugin
endpoints, live inside that same namespace. When configured, official
operational and documentation plugin endpoints mount under `/{basePath}`:

- `/{basePath}/health`
- `/{basePath}/metrics`
- `/{basePath}/docs`
- `/{basePath}/openapi.json`
- `/{basePath}/openapi.yaml`

No public route may bypass that shared mount path.

The canonical interactive documentation endpoint is `/{basePath}/docs`.

Business transports layered on top of the API use that same namespace.
This is where a future GraphQL plugin would belong, for example
`/{basePath}/graphql`.

### 4. CQRS Positioning

CQRS is **native but optional**.

- Without GraphQL, `modular_api` remains a modular REST framework.
- With the future GraphQL plugin enabled, the API may adopt a CQRS profile:
  REST for commands and GraphQL for queries.

This has design impact now, but it is not implementation scope for this stage.

---

## Plugin Model

### 1. Global Plugins

Global plugins should be able to:

- register routes
- register middleware in defined slots
- perform startup validation
- expose capabilities to other plugins
- consume capabilities exposed by other plugins
- run shutdown logic

### 2. Module-Scoped Contributions

The plugin system also needs a module-scoped extension mechanism.

Reason: future plugins such as GraphQL must be able to attach metadata or
behavior to a module without forcing core-specific fields like `schemaPath` or
`resolvers` into the base `module()` API.

That means the plugin ecosystem needs two layers:

- a **global plugin host**
- a **module contribution model**

### 3. Capability Registry

The host should provide a capability registry so plugins can collaborate
without hidden coupling.

Examples:

- `OpenApiPlugin` exposes an OpenAPI capability
- `DocsPlugin` consumes that OpenAPI capability
- `MetricsPlugin` exposes a metrics registrar capability
- `HealthPlugin` exposes a health service or health registration capability

This is preferable to keeping special properties on the core such as
`metrics` or `addHealthCheck()`.

---

## Proposed Host Responsibilities

The plugin host should provide, at minimum:

- core metadata: `basePath`, `title`, `version`
- read-only access to the registered module and use case registry
- route registration
- middleware registration by slot
- capability publication and resolution
- startup validation hooks
- shutdown hooks

The host should not allow plugins to bypass or replace the core use case
lifecycle.

---

## Official Plugin Behavior

### HealthPlugin

- owns `/{basePath}/health`
- owns health-check registration
- owns health-specific metadata such as release information

### MetricsPlugin

- owns `/{basePath}/metrics`
- owns the HTTP metrics middleware
- exposes a public metrics registration capability

### OpenApiPlugin

- owns `/{basePath}/openapi.json` and `/{basePath}/openapi.yaml`
- builds and caches the API specification
- exposes the generated specification as a capability for other plugins

### DocsPlugin

- owns `/{basePath}/docs`
- depends on `OpenApiPlugin`
- renders the interactive documentation UI from the OpenAPI capability

---

## Non-Goals of This Stage

The following are explicitly out of scope for the current implementation stage:

- GraphQL implementation
- transport adapters beyond HTTP
- authentication plugins
- non-API initiatives unrelated to the plugin architecture

---

## Open Design Questions

These questions still need a final decision before implementation begins:

1. Should the plugin contract live in a dedicated package per language, or be
   exported directly from the main SDK package first and split later?
2. What middleware slot names should be public and stable across the three SDKs?
3. What is the exact public shape of the module-contribution API?
4. Which startup errors should be standardized across languages for route and
   capability conflicts?

---

## Immediate Next Step

Implement the plugin host and migrate the current global capabilities to the
official plugin model before starting any GraphQL work.