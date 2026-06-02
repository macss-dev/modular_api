# Plugin Host Contract Matrix

This matrix turns the approved plugin-host contract into concrete test targets
that will be implemented incrementally across Dart, TypeScript, and Python.

## Stage 0 Baseline Targets

| Rule ID | Contract slice | Stage | Dart | TypeScript | Python |
| --- | --- | --- | --- | --- | --- |
| PH-001 | `ModularApi` exposes a public `.plugin()` API | 0 -> 1 | `code/dart/test/plugin_host/plugin_host_stage0_red_test.dart` | `code/ts/test/plugin_host/plugin_host.stage0.red.test.ts` | `code/py/tests/plugin_host/test_stage0_plugin_host_red.py` |
| PH-002 | Public plugin contract types are exported to SDK consumers | 0 -> 1 | `code/dart/test/plugin_host/plugin_host_stage0_red_test.dart` | `code/ts/test/plugin_host/plugin_host.stage0.red.test.ts` | `code/py/tests/plugin_host/test_stage0_plugin_host_red.py` |
| PH-003 | Plugin manifests are captured at registration time without running setup | 0 -> 1 | `code/dart/test/plugin_host/plugin_host_stage0_red_test.dart` | `code/ts/test/plugin_host/plugin_host.stage0.red.test.ts` | `code/py/tests/plugin_host/test_stage0_plugin_host_red.py` |
| PH-004 | Plugin routes resolve under the shared `basePath` only | 0 -> 3 | `code/dart/test/plugin_host/plugin_host_stage0_red_test.dart` | `code/ts/test/plugin_host/plugin_host.stage0.red.test.ts` | `code/py/tests/plugin_host/test_stage0_plugin_host_red.py` |

## Forward Stage Mapping

| Rule family | Planned stage |
| --- | --- |
| Public plugin API and host metadata | Stage 1 |
| Lifecycle ordering, freeze, shutdown | Stage 2 |
| Route registration and basePath normalization | Stage 3 |
| Middleware slots and request context | Stage 4 |
| Capability registry and module extensions | Stage 5 |
| Standardized startup validation and error codes | Stage 6 |
| Health and Metrics plugin migration | Stage 7 |
| OpenAPI and Docs plugin migration | Stage 8 |
| Reference plugin and authoring proof | Stage 9 |