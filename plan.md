# Plugin Host Implementation Plan

**Status:** Active; baseline Stage 00, lifecycle Stage 02, middleware/runtime Stage 04, and the shared-basePath operational-plugin migration are documented in [docs/qa/stage-00.md](docs/qa/stage-00.md), [docs/qa/stage-02.md](docs/qa/stage-02.md), [docs/qa/stage-04.md](docs/qa/stage-04.md), and [docs/qa/stage-08.md](docs/qa/stage-08.md). Public plugin authoring docs now live in [docs/plugin_host_guide.md](docs/plugin_host_guide.md)  
**Scope:** v0.5.0 plugin-host refactor only  
**Applies to:** Dart, TypeScript, Python

**Audit note:** Checkboxes below are marked conservatively from repository evidence and QA artifacts as of 2026-06-01.

**Execution note:** Remaining unchecked items now fall into three buckets and should not be read as a single class of debt:

- **Real remaining work** — tests or features that are still absent and must be implemented before the v0.5.0 milestone can be declared complete.
- **Conservative process gates** — generic workflow/release checklists kept open until the entire milestone is formally closed.
- **Plan drift** — a few older targets assume a slightly different shape than the implementation that shipped (for example, official runtime plugins are auto-mounted by `ModularApi`, so some "without plugin X" absence tests now require roadmap clarification instead of literal implementation).

---

## 1. Purpose

This plan turns the approved architecture and plugin-host contract into an
execution sequence that is strict, test-driven, and reviewable stage by stage.

The objective is to deliver the v0.5.0 plugin infrastructure in all three SDKs
without drifting from the approved target architecture:

- minimal core
- one shared `basePath` per API instance
- official plugins using the same public contract as third-party plugins
- deterministic lifecycle, validation, ordering, and startup failures

This plan is intentionally scoped **before GraphQL**. GraphQL remains out of
scope until the plugin host and official plugins are complete.

---

## 2. Scope Boundaries

### In Scope

- public plugin registration on `ModularApi`
- plugin manifest and host contract in Dart, TypeScript, and Python
- lifecycle orchestration: setup, validate, runtime freeze, shutdown
- route contributions under the shared `basePath`
- middleware slots and plugin request context
- capability registry
- module extension points and contributions
- standardized startup validation and cross-language error codes
- migration of Health, Metrics, OpenAPI, and Docs to official plugins
- reference plugin and plugin-author documentation

### Out of Scope for This Plan

- GraphQL implementation
- CQRS query-side runtime work
- package splitting or marketplace packaging
- multi-provider capabilities
- manifest serialization for external tooling
- middleware opt-out policies per route
- schema validation for plugin-specific module extension payloads

---

## 3. Delivery Rules

- [ ] We execute **one approved stage at a time**.
- [ ] Every stage advances the **same conceptual slice in Dart, TypeScript, and Python**.
- [ ] No stage is considered complete until the three SDKs expose the same semantic behavior.
- [ ] Every stage starts with **red tests first** in all three SDKs.
- [ ] Every stage ends with a **written QA analysis** and explicit approval to continue.
- [ ] No GraphQL work starts before the final stage in this plan is approved as complete.
- [ ] Public docs are updated in the same stage when the public surface changes.
- [ ] Cross-language parity remains a release gate, not an optional extra.

---

## 4. Standard Per-Stage Workflow

The following checklist applies to **every** stage below.

- [ ] Write or update Dart tests first so the target behavior is explicit.
- [ ] Write or update TypeScript tests for the same behavioral slice.
- [ ] Write or update Python tests for the same behavioral slice.
- [ ] Confirm the new tests fail for the intended reason before implementation begins.
- [ ] Implement the minimum code needed to make the stage tests pass in all three SDKs.
- [ ] Refactor only after the stage-specific test set is green.
- [ ] Run `dart test` in `code/dart`.
- [ ] Run `npm test` in `code/ts`.
- [ ] Run `python -m pytest` in `code/py`.
- [ ] Run `pwsh .\code\tests\integration_test\parity_test.ps1` whenever the slice is externally observable over HTTP.
- [ ] Write a QA note for the stage in `docs/qa/stage-XX.md`.
- [ ] Review the QA note and obtain explicit approval before starting the next stage.

---

## 5. Shared Test Strategy

### Contract-Test Locations to Create or Expand

- [x] Dart: `code/dart/test/plugin_host/`
- [x] TypeScript: `code/ts/test/plugin_host/`
- [x] Python: `code/py/tests/plugin_host/`
- [x] Shared fixtures when useful: `code/tests/fixtures/plugin_host/`

### Verification Layers

- [x] Unit-level contract tests for host APIs, ordering rules, and startup failures.
- [x] HTTP integration tests for mounted routes, middleware effects, and basePath behavior.
- [x] Cross-language parity checks for the canonical public endpoints.
- [ ] Documentation checks whenever the public plugin surface changes.

### Current QA Strategy

The three SDKs are first-class peers: each one must run its **full** suite locally
with no per-SDK exceptions. For local closure of the current plugin-host slice,
use this order:

1. Run targeted contract suites for the touched surface in Dart, TypeScript, and Python first.
2. Run the full Dart, TypeScript, and Python suites locally (`dart test`, `npm test`, `python -m pytest`).
3. Run the cross-language parity script after per-SDK suites are green.
4. Finish with `dart analyze`, `npm run build`, and `python -m compileall src`.

Earlier intermittent Windows `pytest` teardown crashes (`access violation` in the
`unraisableexception` GC pass) were a **test-harness** issue, not an SDK gap: on
Windows the default `ProactorEventLoop` (IOCP) is created per request by every
non-context-managed Starlette `TestClient`, and its finalizers occasionally
segfaulted during `gc.collect()`. `code/py/tests/conftest.py` now forces the
`WindowsSelectorEventLoop`, making the full Python suite as reliable as Dart and
TypeScript. Production code is unchanged.

### Stage Completion Definition

- [ ] The targeted slice is green in Dart, TypeScript, and Python.
- [ ] No earlier stage regresses.
- [ ] Required parity coverage is green.
- [ ] The stage QA note records findings, residual risks, and approval recommendation.
- [ ] Public docs affected by the stage are updated before closure.

---

## 6. Stage Plan

### Stage 0 - Baseline, Harness, and Contract-Test Matrix

**Goal:** create the execution harness so later stages can be driven by shared,
observable behavior instead of ad hoc implementation choices.

**Implementation checklist**

- [x] Create a shared contract matrix that maps each approved plugin-host rule to concrete tests.
- [x] Create or reserve plugin-host test folders in Dart, TypeScript, and Python.
- [x] Define the naming convention for stage QA reports.
- [ ] Extend example apps or fixtures so plugin-enabled test servers can run with `basePath = /` and `basePath = /api`.
- [x] Prepare parity-runner updates so the script can validate plugin-host examples without assuming root-mounted operational endpoints forever.

**TDD targets**

- [x] Dart: add the first red tests for `api.plugin(...)`, manifest capture, and basePath-aware plugin routes.
- [x] TypeScript: add the same red tests with equivalent expectations.
- [x] Python: add the same red tests with equivalent expectations.
- [x] Record the expected red-state reasons so later green results are attributable to the intended slice.

**QA gate**

- [x] Verify the baseline is recorded before behavior changes start.
- [x] Verify no production behavior changes are introduced in this stage.
- [x] Verify the parity harness still reflects current externally visible behavior.

**Exit criterion**

- [x] The repo is ready to implement the host incrementally under TDD.

---

### Stage 1 - Public Plugin Surface and Host Metadata

**Goal:** make plugin registration and the public host-facing types real in all
three SDKs without yet implementing the full lifecycle.

**Implementation checklist**

- [x] Dart: add and export the public plugin-facing abstractions (`PluginManifest`, `PluginRequirement`, `Plugin`, `PluginHost`, `HostMetadata`).
- [x] TypeScript: add and export the equivalent public abstractions.
- [x] Python: add and export the equivalent public abstractions.
- [x] Add `api.plugin(plugin)` to `ModularApi` in all three SDKs.
- [x] Ensure plugin registration captures manifests but does not execute plugin setup yet.
- [x] Expose read-only API metadata (`basePath`, `title`, `version`, `hostApiVersion`) through the public host surface.

**TDD targets**

- [ ] Red tests prove that plugin registration preserves registration order.
- [x] Red tests prove that plugin setup does not run during registration.
- [x] Red tests prove that host metadata exposes the configured basePath and API metadata.
- [x] Red tests prove that the new public types are exported and usable from consumer code.

**QA gate**

- [ ] Review public naming consistency across the three SDKs.
- [ ] Verify no framework-specific internal types leak through the public contract.
- [ ] Verify the surface is still small enough for third-party plugin authors.

**Exit criterion**

- [x] An application can register plugin instances through public APIs in all three SDKs.

---

### Stage 2 - Host Lifecycle, Registration Freeze, and Ordering

**Goal:** implement deterministic host-owned lifecycle orchestration.

**Implementation checklist**

- [x] Implement registration, setup, validation, runtime, and shutdown phases in all three SDKs.
- [x] Implement deterministic plugin setup ordering from dependency topology.
- [x] Use registration order as the tiebreaker when there is no dependency edge.
- [x] Freeze host registration before validation begins.
- [x] Execute shutdown hooks in reverse plugin setup order.

**TDD targets**

- [x] Red tests prove that `setup()` runs exactly once per plugin.
- [x] Red tests prove that dependency order controls setup order.
- [x] Red tests prove that reverse order is used for shutdown.
- [x] Red tests prove that late registrations after startup freeze are rejected.
- [x] Red tests prove that a plugin cannot mutate host registrations during runtime.

**QA gate**

- [x] Verify lifecycle order is stable across repeated runs.
- [x] Verify failure during validation aborts startup before the runtime phase.
- [x] Verify shutdown still runs predictably after partial startup success when applicable.

**Exit criterion**

- [x] The plugin host lifecycle is deterministic and host-owned in all three SDKs.

---

### Stage 3 - Route Contributions and Shared basePath Enforcement

**Goal:** make plugin routes first-class while enforcing the approved single
shared mount path model.

**Implementation checklist**

- [x] Implement `registerRoute(...)` on the public host in all three SDKs.
- [x] Normalize leading slashes and collapse duplicate slashes.
- [x] Reject empty plugin-relative paths.
- [x] Resolve final routes as normalized `basePath + relative path`.
- [x] Reject attempts to bypass the shared `basePath`.
- [x] Detect duplicate `(method, finalPath)` pairs before startup completes.
- [ ] Extend example apps or fixtures to demonstrate plugin routes under both `/` and `/api`.

**TDD targets**

- [ ] Red tests cover path normalization edge cases.
- [ ] Red tests cover route collision detection across different plugins.
- [ ] Red tests prove that `basePath = /` still produces rooted final routes.
- [x] Red HTTP tests prove that plugin endpoints appear under `/{basePath}/...` and nowhere else.

**QA gate**

- [x] Verify no public route escapes the shared basePath model.
- [x] Verify the final route table is semantically equivalent across Dart, TypeScript, and Python.
- [x] Verify this stage does not reintroduce mixed root-level versus prefixed public endpoints.

**Exit criterion**

- [x] Plugins can contribute routes safely and consistently under the shared API mount path.

---

### Stage 4 - Middleware Slots and Plugin Request Context

**Goal:** let plugins participate in the HTTP pipeline without quietly
bypassing the core lifecycle.

**Implementation checklist**

- [x] Implement the three public middleware slots: `preRouting`, `preHandler`, and `postHandler`.
- [x] Implement middleware ordering by `(slot, order, plugin setup order)`.
- [x] Keep core request-scoped logging ahead of plugin middleware.
- [x] Expose a semantically equivalent plugin request context in all three SDKs.
- [x] Ensure plugin middleware cannot quietly bypass the core use-case lifecycle: short-circuits are attributable and uncaught pipeline errors are normalized.

**TDD targets**

- [x] Red tests prove that lower `order` values run earlier inside the same slot.
- [x] Red tests prove that registration order breaks ties when `order` matches.
- [x] Red tests prove that core logging still runs first.
- [x] Red tests prove that unknown middleware slots are rejected.
- [x] Red tests prove that plugin handlers receive request id, logger, method, path, headers, query, body, path params, and capability access.
- [x] Red tests prove that completed request logs annotate which plugin middleware short-circuited the pipeline.
- [x] Red tests prove that uncaught plugin-pipeline failures return structured JSON `500` responses.

**QA gate**

- [x] Verify a metrics-style middleware can be implemented with public slots only.
- [x] Verify request-context semantics match across the three SDKs even if framework adapters differ.
- [x] Verify middleware cannot quietly short-circuit the approved lifecycle rules.

**Exit criterion**

- [x] Plugins can participate in the pipeline only through stable public slots and request context.

---

### Stage 5 - Capability Registry and Module Extensions

**Goal:** implement the two core extensibility mechanisms that let plugins
collaborate without polluting the core API.

**Implementation checklist**

- [x] Implement `exposeCapability`, `resolveCapability`, and `requireCapability` in all three SDKs.
- [x] Keep capability access read-only to consumers.
- [x] Enforce globally unique capability ids.
- [x] Implement module extension-point declaration and module extension contribution APIs.
- [x] Support both `single` and `multi` extension-point modes.
- [x] Store module extension payloads opaquely in the core.
- [x] Preserve deterministic ordering for multi-valued contributions.

**TDD targets**

- [ ] Red tests prove that required capabilities can be resolved after setup.
- [ ] Red tests prove that missing required capabilities fail startup.
- [ ] Red tests prove that duplicate capability providers fail startup.
- [ ] Red tests prove that single-valued extension points reject duplicate contributions.
- [ ] Red tests prove that multi-valued extension points preserve deterministic contribution order.
- [ ] Red tests prove that the core does not need plugin-specific fields on modules to store extension data.

**QA gate**

- [ ] Verify plugin collaboration can happen without direct access to mutable host internals.
- [ ] Verify the core remains unaware of plugin-specific payload schemas.
- [ ] Verify the public contract stays compatible with future transports such as GraphQL without implementing them now.

**Exit criterion**

- [ ] Plugins can expose shared services and attach module-scoped opaque metadata through public APIs only.

---

### Stage 6 - Startup Validation Matrix and Standard Error Codes

**Goal:** make cross-language startup failures deterministic, explicit, and
reviewable.

**Implementation checklist**

- [ ] Implement the approved error-code inventory in Dart, TypeScript, and Python.
- [x] Ensure SDK-specific exception types preserve the canonical error code strings.
- [x] Include structured error details such as `pluginId`, `resourceId`, and human-readable message where applicable.
- [ ] Centralize startup validation so route, capability, dependency, slot, and module-extension failures all pass through the same semantic model.

**TDD targets**

- [x] Red tests cover `PLUGIN_ID_CONFLICT`.
- [ ] Red tests cover `PLUGIN_HOST_VERSION_UNSUPPORTED`.
- [ ] Red tests cover `PLUGIN_DEPENDENCY_MISSING`.
- [ ] Red tests cover `PLUGIN_DEPENDENCY_CYCLE`.
- [ ] Red tests cover `CAPABILITY_REQUIRED_MISSING`.
- [ ] Red tests cover `CAPABILITY_CONFLICT`.
- [ ] Red tests cover `ROUTE_CONFLICT`.
- [ ] Red tests cover `MIDDLEWARE_SLOT_UNKNOWN`.
- [ ] Red tests cover `MODULE_EXTENSION_POINT_CONFLICT`.
- [ ] Red tests cover `MODULE_EXTENSION_CONFLICT`.
- [x] Red tests cover `PLUGIN_VALIDATION_FAILED`.

**QA gate**

- [ ] Verify the exact error code inventory matches across the three SDKs.
- [ ] Verify startup failures are early, deterministic, and actionable.
- [ ] Verify the error payloads are precise enough for developers and CI diagnostics.

**Exit criterion**

- [ ] The host reports the same classes of startup failures consistently across languages.

---

### Stage 7 - Migrate HealthPlugin and MetricsPlugin

**Goal:** move the operational runtime surface out of the core and into
official plugins without losing behavioral parity.

**Implementation checklist**

- [x] Implement `HealthPlugin` on the public plugin contract in all three SDKs.
- [x] Implement `MetricsPlugin` on the public plugin contract in all three SDKs.
- [x] Register `/{basePath}/health` through the plugin host, not through core-owned shortcuts.
- [x] Register `/{basePath}/metrics` through the plugin host, not through core-owned shortcuts.
- [x] Move HTTP metrics collection into plugin middleware targeting `preRouting`.
- [ ] Expose the public metrics registry capability through `MetricsPlugin`.
- [x] Remove or retire the direct core mounting path for these capabilities.

**TDD targets**

_Execution note: the current runtime mounts official health/metrics plugins automatically through `buildRuntimePlugins(...)`, so the two "without plugin" absence tests below are now roadmap-clarification items unless the API gains an explicit opt-out surface._

- [ ] Red tests prove that APIs without `HealthPlugin` do not expose the health endpoint.
- [ ] Red tests prove that APIs without `MetricsPlugin` do not expose the metrics endpoint.
- [ ] Red tests prove that enabled plugins mount their endpoints correctly under both `/` and `/api`.
- [ ] Red tests prove that metrics labels use normalized routes under the shared basePath model.
- [ ] Red tests prove that metrics collection can be enabled without private host hooks.

**QA gate**

- [ ] Verify operational payloads and content types remain compatible with current expectations unless a deliberate contract change is approved.
- [x] Verify there is no hidden core fallback that still mounts these endpoints directly.
- [x] Verify parity coverage exercises both operational plugins in all three SDKs.

**Exit criterion**

- [ ] Health and metrics are official plugins that use only the public contract.

---

### Stage 8 - Migrate OpenApiPlugin and DocsPlugin

**Goal:** complete the official plugin migration for the documentation surface.

**Implementation checklist**

- [x] Implement `OpenApiPlugin` on the public plugin contract in all three SDKs.
- [x] Register `/{basePath}/openapi.json` and `/{basePath}/openapi.yaml` through the plugin host.
- [x] Expose the OpenAPI capability through `OpenApiPlugin`.
- [x] Implement `DocsPlugin` on the public plugin contract in all three SDKs.
- [x] Make `DocsPlugin` require the OpenAPI capability instead of rebuilding the spec itself.
- [x] Register `/{basePath}/docs` through the plugin host.
- [x] Remove or retire the direct core mounting path for docs and OpenAPI endpoints.

**TDD targets**

_Execution note: the current runtime mounts official OpenAPI/Docs plugins automatically through `buildRuntimePlugins(...)`, so the "without plugin" absence tests below are not direct closure blockers unless the API grows a public opt-out mechanism for official runtime plugins._

- [ ] Red tests prove that `DocsPlugin` fails startup when the required OpenAPI capability is absent.
- [ ] Red tests prove that APIs without `OpenApiPlugin` do not expose raw spec endpoints.
- [ ] Red tests prove that APIs without `DocsPlugin` do not expose the docs endpoint.
- [ ] Red HTTP tests prove that docs and raw spec routes resolve under both `/` and `/api`.
- [x] Red tests prove that the docs UI points to the correct basePath-aware OpenAPI URL.

**QA gate**

- [x] Verify HTML docs, JSON spec, YAML spec, and capability handoff are equivalent across the three SDKs.
- [x] Verify docs remain a consumer of the OpenAPI capability, not a second spec generator.
- [x] Verify parity coverage includes the canonical docs and spec endpoints under the shared basePath model.

**Exit criterion**

- [x] Docs and OpenAPI are official plugins that consume and expose capabilities through the public host.

---

### Stage 9 - Reference Plugin, Authoring Docs, Migration Guide, and Release Readiness

**Goal:** prove the public contract is sufficient for real users and close the
v0.5.0 milestone cleanly.

**Implementation checklist**

- [ ] Build a minimal third-party-style reference plugin in Dart using only the public contract.
- [ ] Build the equivalent reference plugin in TypeScript using only the public contract.
- [ ] Build the equivalent reference plugin in Python using only the public contract.
- [x] Document how to build custom plugins for Dart, TypeScript, and Python.
- [ ] Document migration from core-managed global endpoints to plugin-managed official endpoints.
- [x] Update architecture-facing docs so implementation status matches reality.
- [x] Prepare synchronized version bumps and changelog entries for all three SDKs.
- [ ] Prepare release notes that explicitly describe the plugin-host milestone and any migration impact.

**TDD targets**

- [ ] Red tests prove that the reference plugin can register routes, middleware, or capabilities without private APIs.
- [ ] Red tests prove that an application can mount official plugins plus the reference plugin together.
- [ ] Red tests prove that the public plugin contract is sufficient from outside the core package internals.

**QA gate**

- [ ] Verify a new contributor can follow the docs and build a working custom plugin in each SDK.
- [ ] Verify release notes, changelogs, and version numbers are synchronized across Dart, TypeScript, and Python.
- [x] Verify the full parity suite passes with the official plugins mounted through the public host.
- [ ] Verify the repo is ready to declare the v0.5.0 plugin infrastructure milestone complete.

**Exit criterion**

- [ ] A developer outside the project can build and mount a custom plugin using the same public contract as the official plugins.

---

## 7. Required QA Report Contents for Every Stage

Each `docs/qa/stage-XX.md` report must answer the same questions.

- [ ] What exact slice was implemented in this stage?
- [ ] Which tests were added first, and what was the initial red state?
- [ ] Which commands were executed in Dart, TypeScript, Python, and parity validation?
- [ ] What public behavior changed, if any?
- [ ] What regressions were checked explicitly?
- [ ] What cross-language differences were found and how were they resolved?
- [ ] What residual risks or open questions remain?
- [ ] Is the stage recommended for approval, or must it be reworked first?

---

## 8. Final Release Gate

The v0.5.0 implementation is not complete until all of the following are true.

- [ ] Stages 0 through 9 are approved.
- [ ] Dart, TypeScript, and Python expose equivalent plugin-host behavior.
- [x] Health, Metrics, OpenAPI, and Docs are mounted by official plugins, not by core-owned shortcuts.
- [x] All public routes resolve under the shared `basePath`.
- [ ] The full test suite is green in all three SDKs.
- [x] The parity script is green for the canonical public endpoints.
- [ ] Public docs match the implemented runtime behavior.
- [x] Versions and changelogs are synchronized across the three SDKs.

---

## 9. Review Mode

This file is intended to be reviewed and approved **stage by stage**.

The expected execution loop is:

1. Approve the next stage.
2. Execute that stage in Dart, TypeScript, and Python under TDD.
3. Produce the stage QA report.
4. Review the QA findings.
5. Approve or reject the next stage.
