# Stage 02 QA

## Slice

Deterministic plugin-host lifecycle orchestration across Dart, TypeScript, and
Python:

- plugin setup now follows dependency topology instead of raw registration order
- registration order remains the deterministic tiebreaker when there is no
  dependency edge
- validation now runs after registration freeze and can abort startup
- shutdown now runs in reverse setup order through host-owned orchestration
- startup failure now drains already-registered shutdown hooks before rethrowing
- late host mutation after startup freeze is rejected in all three SDKs

## Red-first Evidence

### TypeScript

Command:

```powershell
Push-Location code/ts
npm test -- test/plugin_host/plugin_host.lifecycle.test.ts
Pop-Location
```

Observed red state before implementation:

- dependent plugins still ran in registration order instead of dependency order
- `validate()` was not invoked during startup
- plugin `shutdown()` was not invoked in reverse setup order

### Dart

Command:

```powershell
Push-Location code/dart
dart test test/plugin_host/plugin_host_lifecycle_test.dart
Pop-Location
```

Observed red state before implementation:

- dependent plugins still ran in registration order instead of dependency order
- validation hooks were not invoked during startup
- shutdown hooks were not wired to server shutdown

### Python

Command used in this workspace:

```powershell
Push-Location code/py
$env:PYTHONPATH='src'
.\.venv\Scripts\python.exe -m pytest tests/plugin_host/test_plugin_host_lifecycle.py
Remove-Item Env:PYTHONPATH
Pop-Location
```

Observed red state before implementation:

- dependent plugins still ran in registration order instead of dependency order
- validation hooks were not invoked during startup
- shutdown hooks were not wired into the ASGI app lifecycle

## Commands Executed

- targeted lifecycle tests in Dart, TypeScript, and Python
- full regression suites:
  - `dart test`
  - `npm test`
  - `python -m pytest` with `PYTHONPATH=src`
- cross-language smoke regression:
  - `pwsh .\code\tests\integration_test\parity_test.ps1`
- final static/package validation:
  - `dart analyze`
  - `npm run build`
  - `python -m compileall src`

## Public Behavior Change

- plugin setup order is now dependency-aware instead of raw registration-order only
- plugin validation is now an explicit startup phase after host freeze
- plugin shutdown is now host-owned and runs in reverse setup order
- plugin attempts to mutate host registrations after startup freeze fail deterministically

## Regressions Checked Explicitly

- targeted lifecycle suites passed in all three SDKs
- full Dart suite: 317 tests passed
- full TypeScript suite: 24 files, 230 tests passed
- full Python suite: 334 tests passed
- parity runner: 219 assertions passed with the three example servers running
- TypeScript package build passed
- Dart static analysis passed
- Python source compile check passed

## Cross-language Findings

- TypeScript already had a server close hook; the missing part was registering
  plugin shutdown callbacks and executing validation after freeze
- Dart required a managed `HttpServer` wrapper so `serve()` could preserve its
  public return type while still triggering plugin-host shutdown on `close()`
- Python's installed Starlette version in this workspace does not expose
  `add_event_handler`; shutdown had to be wired through the supported `lifespan`
  hook instead

## Residual Risks

- dependency missing and dependency cycle error paths are implemented but not yet
  covered by dedicated cross-language tests; they remain better closed in the
  startup-validation stage
- the broader release/documentation work for third-party plugin authoring is
  still outside this stage and remains open in later plan stages

## Recommendation

Stage 02 lifecycle orchestration is implemented and validated across Dart,
TypeScript, and Python, and is recommended for approval.