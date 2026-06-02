# Plugin Host Guide

This guide documents the current public plugin-host surface available in Dart,
TypeScript, and Python as of v0.4.7.

It is intentionally limited to behavior that exists today. It does not document
future GraphQL work or later hardening that is still planned but not yet
implemented.

## What Is Public Today

All three SDKs expose the same conceptual plugin model:

- `ModularApi.plugin(...)` registers a plugin instance.
- A plugin declares a manifest with identity, version, host compatibility, and
  optional dependencies.
- `setup(...)` runs during startup, not during registration.
- Plugins can register routes, startup validations, shutdown callbacks,
  capabilities, middleware, and module-extension data through the public host.
- Host metadata exposes the resolved `basePath`, API title, API version, and
  host API version.
- Official plugins use the same public contract as third-party plugins.

## Lifecycle Contract

Startup is host-owned and deterministic:

1. Plugins are registered in application code with `api.plugin(...)`.
2. At startup, the host orders plugins by declared plugin dependencies.
3. `setup(...)` runs once per plugin.
4. Host registration freezes before validation begins.
5. `validate(...)` or host-added startup validations can abort startup.
6. If startup fails after some plugins already set up, registered shutdown hooks
   still run in reverse setup order before the error is rethrown.
7. On normal application shutdown, registered shutdown hooks run in reverse
   setup order.

Two invariants matter for authors:

- All public routes resolve under the API instance `basePath`.
- Plugins cannot mutate host registrations after startup freeze.

## Route Rules

- Plugin routes are declared as relative paths such as `/hello-plugin`.
- The host resolves the final path as `basePath + relative plugin path`.
- Empty plugin-relative paths are rejected.
- Duplicate `(method, finalPath)` pairs are rejected before startup completes.

## Middleware Status

All three public middleware slots are active in the three SDKs:
`preRouting`, `preHandler`, and `postHandler`.

Ordering is deterministic inside the host:

- core request-scoped logging still runs ahead of plugin middleware
- middleware execution is grouped by slot
- lower `order` values run earlier inside the same slot
- plugin setup order breaks ties when `order` matches

Middleware handlers still use the native continuation semantics of their host
framework, so plugin authors must call the inner handler or `next()` when they
intend the normal route or use-case lifecycle to continue.

## Minimal Plugin Examples

### TypeScript

```ts
import {
  ModularApi,
  type Plugin,
  type PluginHost,
  type PluginManifest,
} from '@macss/modular-api';

class HelloPlugin implements Plugin {
  readonly manifest: PluginManifest = {
    id: 'acme.hello',
    displayName: 'Hello Plugin',
    version: '0.1.0',
    hostApiVersion: '>=0.1.0 <0.2.0',
  };

  setup(host: PluginHost): void {
    host.registerRoute({
      id: 'hello-plugin',
      method: 'GET',
      path: '/hello-plugin',
      visibility: 'custom',
      handler: () => ({
        status: 200,
        body: {
          ok: true,
          basePath: host.metadata().basePath,
        },
      }),
    });
  }

  validate() {
    return [];
  }
}

const api = new ModularApi({ basePath: '/api' }).plugin(new HelloPlugin());
await api.serve({ port: 8080 });
```

Optional hooks:

- `validate(host)` returns startup validation results.
- `shutdown()` lets the host clean up plugin-owned resources.

### Dart

```dart
import 'dart:convert';

import 'package:modular_api/modular_api.dart';

class HelloPlugin implements Plugin, ValidatingPlugin {
  @override
  final manifest = const PluginManifest(
    id: 'acme.hello',
    displayName: 'Hello Plugin',
    version: '0.1.0',
    hostApiVersion: '>=0.1.0 <0.2.0',
  );

  @override
  void setup(PluginHost host) {
    host.registerRoute(
      PluginRoute(
        id: 'hello-plugin',
        method: 'GET',
        path: '/hello-plugin',
        visibility: 'custom',
        handler: (_) => Response.ok(
          jsonEncode({
            'ok': true,
            'basePath': host.metadata().basePath,
          }),
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
  }

  @override
  List<PluginValidationResult> validate(PluginHost host) => const [];
}

Future<void> main() async {
  final api = ModularApi(basePath: '/api')..plugin(HelloPlugin());
  await api.serve(port: 8080);
}
```

Optional hooks:

- `ValidatingPlugin.validate(host)` returns startup validation results.
- `ShutdownAwarePlugin.shutdown()` lets the host clean up plugin-owned
  resources.

### Python

```python
from modular_api import ModularApi, Plugin, PluginHost, PluginManifest, PluginRoute


class HelloPlugin(Plugin):
    manifest = PluginManifest(
        id="acme.hello",
        display_name="Hello Plugin",
        version="0.1.0",
        host_api_version=">=0.1.0 <0.2.0",
    )

    def setup(self, host: PluginHost) -> None:
        host.register_route(
            PluginRoute(
                id="hello-plugin",
                method="GET",
                path="/hello-plugin",
                visibility="custom",
                handler=lambda _: {
                    "status": 200,
                    "body": {
                        "ok": True,
                        "basePath": host.metadata().base_path,
                    },
                },
            )
        )

    def validate(self, host: PluginHost):
        return []


api = ModularApi(base_path="/api")
api.plugin(HelloPlugin())
app = api.build()
```

Optional hooks:

- `validate(host)` returns startup validation results.
- `async shutdown()` lets the host clean up plugin-owned resources.

## Current Limits

- Middleware handlers still use framework-native continuation semantics.
  Deliberate early termination remains part of the public contract, but the
  host now records attributable short-circuit metadata in the completed-request
  log and normalizes uncaught plugin-pipeline exceptions to structured JSON
  `500` responses.
- Dependency-missing and dependency-cycle failures exist in the public contract,
  but broader startup-validation coverage is still being expanded.
- The public metrics capability remains an open follow-up even though the
  metrics endpoint is already hosted by the official plugin.

## Related Docs

- [docs/architecture.md](docs/architecture.md) - target architecture
- [docs/qa/stage-04.md](docs/qa/stage-04.md) - middleware-slot and request-context QA evidence
- [docs/qa/stage-02.md](docs/qa/stage-02.md) - lifecycle QA evidence
- [docs/qa/stage-08.md](docs/qa/stage-08.md) - official operational plugin migration QA