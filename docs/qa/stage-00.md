# Stage 00 QA

## Slice

Baseline harness only:

- created plugin-host baseline fixtures
- created first red tests in Dart, TypeScript, and Python
- prepared the parity runner for future basePath-aware operational endpoints without changing current runtime expectations

No production runtime behavior was changed in this stage.

## Red-first Evidence

### Dart

Command:

```powershell
Push-Location code/dart
dart test test/plugin_host/plugin_host_stage0_red_test.dart
Pop-Location
```

Observed red state:

- `ModularApi.plugin(...)` does not exist
- `Plugin`, `PluginManifest`, `PluginHost`, and `PluginRoute` do not exist yet

### TypeScript

Command:

```powershell
Push-Location code/ts
npm test -- test/plugin_host/plugin_host.stage0.red.test.ts
Pop-Location
```

Observed red state:

- `api.plugin is not a function`
- route test also fails at the same missing plugin-registration entry point

### Python

Command used in this workspace:

```powershell
Push-Location code/py
$env:PYTHONPATH='src'
.\.venv\Scripts\python.exe -m pytest tests/plugin_host/test_stage0_plugin_host_red.py
Remove-Item Env:PYTHONPATH
Pop-Location
```

Observed red state:

- `Plugin` cannot be imported from `modular_api`
- therefore the public plugin contract is not implemented yet

## Commands Executed

- `dart test test/plugin_host/plugin_host_stage0_red_test.dart`
- `npm test -- test/plugin_host/plugin_host.stage0.red.test.ts`
- `.\.venv\Scripts\python.exe -m pytest tests/plugin_host/test_stage0_plugin_host_red.py` with `PYTHONPATH=src`

## Cross-language Findings

- The missing capability is the same in all three SDKs: no public plugin-host surface exists yet.
- Dart fails at compile/load time because the public types do not exist.
- TypeScript reaches runtime and fails on the missing `.plugin()` method.
- Python fails at import time because the plugin symbols are not exported.

## Residual Risks

- The Python local test command requires `PYTHONPATH=src` in this workspace unless the package is installed into the venv beforehand.
- The parity suite still validates the current runtime topology by default: module routes under `/api/v1`, operational routes at root. The helper functions now isolate that assumption for later migration.

## Recommendation

Stage 00 is complete and ready to serve as the baseline for Stage 01 implementation.