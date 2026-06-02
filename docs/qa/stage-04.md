# Stage 04 QA

## Slice

Middleware-slot activation and plugin request-context parity across Dart,
TypeScript, and Python:

- `preRouting`, `preHandler`, and `postHandler` now execute in all three SDKs
- middleware ordering is deterministic by `(slot, order, plugin setup order)`
- unknown middleware slots now fail startup deterministically
- plugin route handlers receive equivalent request context in the three SDKs
- core request-scoped logging remains ahead of plugin middleware
- completed request logs now annotate attributable plugin short-circuits
- uncaught plugin-pipeline exceptions now normalize to structured JSON `500`

## Red-first Evidence

### TypeScript

Command:

```powershell
Push-Location code/ts
npm test -- test/plugin_host/plugin_host.middleware_slots.test.ts
Pop-Location
```

Observed red state before implementation:

- `preHandler` and `postHandler` were declared publicly but not executed at runtime
- middleware ordering did not include a deterministic tie-break beyond `order`
- unknown middleware slots were accepted instead of failing startup

### Dart

Command:

```powershell
Push-Location code/dart
dart test test/plugin_host/plugin_host_middleware_slots_test.dart
Pop-Location
```

Observed red state before implementation:

- `preHandler` and `postHandler` were not wired into the request pipeline
- middleware ordering only considered `order`
- unknown middleware slots were accepted during startup

### Python

Command used in this workspace:

```powershell
Push-Location code/py
$env:PYTHONPATH='src'
.\.venv\Scripts\python.exe -m pytest tests/plugin_host/test_plugin_host_middleware_slots.py
Remove-Item Env:PYTHONPATH
Pop-Location
```

Observed red state before implementation:

- `preHandler` and `postHandler` were not installed in the ASGI middleware pipeline
- middleware ordering only considered `order`
- unknown middleware slots were accepted during build/startup

## Commands Executed

- targeted middleware-slot tests in Dart, TypeScript, and Python
- targeted guardrail tests in Dart, TypeScript, and Python
- full regression suites:
  - `dart test`
  - `npm test`
  - `python -m pytest` with `PYTHONPATH=src` (rerun in this Windows workspace hit a fatal access violation during teardown; affected-surface regression was rerun instead)
- cross-language regression:
  - `pwsh .\code\tests\integration_test\parity_test.ps1`
- final static/package validation:
  - `dart analyze`
  - `npm run build`
  - `python -m compileall src`

## Public Behavior Change

- all three public middleware slots are now active in Dart, TypeScript, and Python
- middleware execution is now deterministic inside the host by slot, explicit `order`, and plugin setup order
- invalid middleware-slot declarations now fail startup with `PLUGIN_VALIDATION_FAILED`
- plugin route handlers continue to receive equivalent request context across the three SDKs
- request-completed logs now expose `short_circuit_*` metadata when a plugin middleware terminates before the core handler
- uncaught plugin-pipeline failures now return structured JSON `500` responses in all three SDKs

## Regressions Checked Explicitly

- focused Stage 04 suites passed in all three SDKs
- focused guardrail suites passed in all three SDKs
- full Dart suite: 322 tests passed
- full TypeScript suite: 26 files, 235 tests passed
- focused Python regression on touched surfaces: 34 tests passed
- full Python suite rerun in this Windows workspace hit a fatal access violation during pytest teardown before completion
- parity runner: 219 assertions passed with the three example servers running
- TypeScript package build passed
- Dart static analysis passed
- Python source compile check passed

## Cross-language Findings

- TypeScript and Dart both apply `preHandler` and `postHandler` through the existing middleware pipeline builder, while Python required explicit LIFO installation order in the ASGI stack to preserve the same observable execution order
- the deterministic tiebreak comes from plugin setup order because middleware is registered during setup in all three SDKs
- plugin route request-context semantics were already aligned; Stage 04 mainly activated the missing runtime slots and startup validation path

## Residual Risks

- middleware handlers still use framework-native continuation semantics in all three SDKs, so deliberate early termination remains part of the public contract; the follow-up hardening now makes those exits attributable in logs and prevents uncaught plugin-pipeline exceptions from escaping as framework-default error pages
- broader startup-validation coverage for dependency-missing and dependency-cycle failures remains open for later stages

## Recommendation

Stage 04 middleware-slot activation, request-context parity, and the immediate
middleware guardrails are implemented and fully green across Dart,
TypeScript, and Python. Deliberate early termination remains a supported public
contract, but it is no longer quiet and uncaught plugin-pipeline errors no
longer leak framework-default error handling.