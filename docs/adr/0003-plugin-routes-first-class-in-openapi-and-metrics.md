# 3. Plugin Routes Are First-Class in OpenAPI and Metrics

Date: 2026-06-11

## Status

Accepted

## Context

The plugin host lets plugins register public routes (`host.registerRoute`) under the shared
`basePath`. This is the sanctioned mechanism for transport extensions — notably binary endpoints
(serve an image as a `Buffer` with its own `Content-Type`, accept multipart uploads), which the
JSON-only use case core deliberately does not cover.

During the migration of the Fotos API (first real consumer of the plugin host on 0.4.8), a
specification experiment produced three findings with evidence:

1. **Plugin routes do not appear in `/openapi.json` or `/docs`.** The OpenAPI spec is built solely
   from the use case registry. A consumer-facing binary endpoint served by a plugin is invisible in
   the generated documentation. The litmus test: if the OpenAPI document were written by hand, those
   endpoints would be included — a generated spec that omits them is incomplete.
2. **Plugin routes are labeled `route="UNMATCHED"` in `http_requests_total`.** The metrics
   middleware only recognizes paths from the use case registry, so per-endpoint latency and error
   rates are unavailable for plugin routes.

(A third suspected finding — stale root-path defaults in the metrics/logging exclusions — was
disproven on evidence recount: both the MetricsPlugin and the logging middleware already derive
their exclusions from `operationalRoutePaths(basePath)`. No change needed there.)

A workaround existed for finding 1 — mutating the spec via the `modular_api.openapi.spec`
capability — but user plugins run `setup()` before official plugins, so the capability does not
exist yet when user plugins could use it. It was discarded as a hack.

## Decision

Plugin routes become first-class citizens of the operational surfaces:

1. **OpenAPI contribution on the route itself.** `PluginRoute` gains an optional `openapi` field
   holding a standard OpenAPI Operation object (summary, parameters, requestBody, responses —
   including binary content types such as `image/jpeg` with `schema: { type: string, format:
   binary }`). No bespoke DSL: a plugin author writes exactly what they would write by hand.
   The route and its documentation travel together (cohesion); `manifest.contributes` remains
   available for other contribution types.
2. **The host exposes registered plugin routes.** `PluginHost` gains a `routes()` view (analogous
   to the existing `useCases()`), returning method, absolute mounted path, visibility, and the
   `openapi` operation when present.
3. **The OpenApiPlugin merges plugin routes into the spec.** Routes with visibility `custom` or
   `transport` and an `openapi` operation are added to `paths`. `operational` routes are not
   documented by default (health/metrics/docs do not belong to the business contract). The current
   plugin ordering works in favor: user plugins register during their `setup()`, official plugins
   build afterwards.
4. **The MetricsPlugin recognizes plugin routes.** Registered plugin route paths join
   `registeredPaths`, so plugin routes receive their real route label instead of `UNMATCHED`.

These changes are part of the 0.5.0 line. TypeScript ships first (validated by the Fotos API as
the real-world consumer, using a local `file:` dependency during development); Dart and Python
reach parity within the synchronized 0.5.0 release (per ADR-0002).

## Consequences

- **Generated documentation is complete** — JSON use cases and plugin transport endpoints appear
  in the same `/docs` and `/openapi.json|yaml`, which is the contract consumers actually face.
- **Per-endpoint observability covers plugins** — latency/error metrics work for binary endpoints
  without plugin-side workaround metrics.
- **The `openapi` field is optional** — existing plugins remain valid; undocumented routes simply
  do not appear in the spec (and can be flagged by a future lint/validation).
- **Cross-SDK work** — the plugin contract change must be mirrored in Dart and Python for the
  synchronized 0.5.0 release; until then, the TS SDK temporarily leads (accepted by ADR-0002's
  parity-bump policy applied at release time).
- **Official plugins keep using the public contract** — HealthPlugin and friends may adopt the
  same `openapi` field later if documenting operational endpoints ever becomes desirable, without
  any special-casing (invariant: official plugins use the same public contract as third-party
  plugins).
