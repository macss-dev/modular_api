# Stage 08 QA

## Slice

Shared-basePath operational-surface migration across Dart, TypeScript, and
Python:

- operational endpoints now mount under the same `basePath` as business routes
- Health, Metrics, OpenAPI, and Docs are applied through the runtime plugin host
- docs HTML now points to the canonical basePath-aware OpenAPI JSON endpoint
- lifecycle hardening added for startup-time duplicate plugin-id rejection
- parity examples and the cross-language parity runner were updated to the new
  externally visible contract

This execution window covers the externally observable portion of the Stage 07
and Stage 08 migration because the four operational endpoints are validated as a
single HTTP surface.

## Red-first Evidence

### TypeScript

Commands:

```powershell
Push-Location code/ts
npm test -- test/plugin_host/plugin_host.lifecycle.test.ts
npm test -- test/plugin_host/official_plugins_basepath.test.ts
Pop-Location
```

Observed red state before implementation:

- duplicate plugin ids were not rejected at startup
- operational endpoints still resolved at root instead of under `basePath`

### Dart

Commands:

```powershell
Push-Location code/dart
dart test test/plugin_host/plugin_host_lifecycle_test.dart
dart test test/plugin_host/official_plugins_basepath_test.dart
Pop-Location
```

Observed red state before implementation:

- duplicate plugin ids were not rejected at startup
- health, metrics, docs, and OpenAPI still resolved outside the shared
  `basePath`

### Python

Commands used in this workspace:

```powershell
Push-Location code/py
$env:PYTHONPATH='src'
.\.venv\Scripts\python.exe -m pytest tests/plugin_host/test_plugin_host_lifecycle.py
.\.venv\Scripts\python.exe -m pytest tests/plugin_host/test_official_plugins_basepath.py
Remove-Item Env:PYTHONPATH
Pop-Location
```

Observed red state before implementation:

- duplicate plugin ids were not rejected at build/startup time
- operational endpoints still resolved outside the shared `basePath`

## Commands Executed

- targeted lifecycle tests in Dart, TypeScript, and Python
- targeted operational basePath tests in Dart, TypeScript, and Python
- affected integration suites for logging, metrics, OpenAPI, and ModularApi behavior
- `pwsh .\code\tests\integration_test\parity_test.ps1`
- full test suites:
  - `dart test`
  - `npm test`
  - `python -m pytest` with `PYTHONPATH=src`
- final static/package validation:
  - `dart analyze`
  - `npm run build`
  - `python -m compileall src`

## Public Behavior Change

- `/{basePath}/health` is now the canonical health endpoint
- `/{basePath}/metrics` is now the canonical metrics endpoint when metrics are enabled
- `/{basePath}/openapi.json` and `/{basePath}/openapi.yaml` are now the canonical raw spec endpoints
- `/{basePath}/docs` now loads Swagger UI against the basePath-aware OpenAPI URL
- mixed root-level operational routes versus prefixed business routes are no longer exposed

## Regressions Checked Explicitly

- full Dart suite: 312 tests passed
- full TypeScript suite: 24 files, 225 tests passed
- full Python suite: 329 tests passed
- parity runner: 219 assertions passed with the three example servers running
- TypeScript package build passed
- Dart static analysis passed
- Python source compile check passed

## Cross-language Findings

- Python local execution in this workspace requires `PYTHONPATH=src` unless the
  package is preinstalled into the virtual environment
- the parity runner needed `npx --yes tsx` to avoid an interactive install prompt
- PowerShell query-string interpolation in the parity script required explicit
  string formatting to avoid treating `?tz` as part of the variable name

## Residual Risks

- `plan.md` still reflects the broader staged roadmap; this note only closes the
  shared-basePath operational-surface slice that is now implemented and green
- later roadmap items such as deeper lifecycle/dependency orchestration and
  broader release bookkeeping should be reviewed against the remaining unchecked
  plan items before declaring the entire plugin-host roadmap complete

## Recommendation

The shared-basePath operational-plugin migration is complete, validated across
the three SDKs, and recommended for approval for this slice.