# modular_api

> Build modular, use-case-centric HTTP APIs in Dart, TypeScript, and Python.

`modular_api` is a monorepo of official SDKs for building modular HTTP APIs where each endpoint maps to one use case. The core is intentionally small: modules, use cases, DTOs, request lifecycle, HTTP pipeline, request-scoped logging, and a plugin host.

The approved plugin-host direction formalizes `/health`, `/metrics`, `/docs`, `/openapi.json`, and `/openapi.yaml` as official plugins mounted under the shared `basePath`. That mount path defaults to `/`, and every public route for an API instance must respect it uniformly. An API mounted at `/api/v1` therefore exposes `/api/v1/health`, `/api/v1/metrics`, `/api/v1/docs`, `/api/v1/openapi.json`, and `/api/v1/openapi.yaml`. Third-party plugins will use that same public contract.

GraphQL is a future official plugin. When enabled it will provide the query side of an optional CQRS profile. REST-only APIs remain a first-class use case.

---

## Monorepo Structure

```
modular_api/
  code/
    dart/
      modular_api/               -> pub.dev: modular_api
      modular_api_rest_client/
      modular_api_graphql_client/
      modular_api_sqlserver/
      modular_api_postgres/
    ts/
      modular_api/               -> npm: @macss/modular-api
      modular_api_rest_client/
      modular_api_graphql_client/
      modular_api_sqlserver/
      modular_api_postgres/
    py/
      modular_api/               -> PyPI: macss-modular-api
      modular_api_rest_client/
      modular_api_graphql_client/
      modular_api_sqlserver/
      modular_api_postgres/
    docs-ui/     -> npm: @macss/docs-ui
    tests/       -> cross-language parity tests
  docs/          -> public product and SDK documentation
  README.md
```

Each SDK is independently versioned and published. The public API and external behavior are kept aligned across the three implementations.

---

## SDKs

| SDK | Package | Registry | Status |
|---|---|---|---|
| `code/dart/modular_api/` | `modular_api` | [pub.dev](https://pub.dev/packages/modular_api) | ✅ Published |
| `code/ts/modular_api/` | `@macss/modular-api` | [npm](https://www.npmjs.com/package/@macss/modular-api) | ✅ Published |
| `code/py/modular_api/` | `macss-modular-api` | [PyPI](https://pypi.org/project/macss-modular-api/) | ✅ Published |

---

## Core Model

### Modules

Modules are written by the user. Each module owns one domain and groups its use cases, DTOs, repository ports, and adapters. Modules do not call each other directly through the framework.

### Use Cases

Each endpoint maps to one use case. The framework handles payload extraction, validation, logger injection, execution, and serialization. The user implements only business logic.

### Plugins

Optional capabilities are now provided by official plugins mounted through the
public host contract.

| Capability | Plugin route under shared `basePath` | Target plugin |
|---|---|---|
| Health checks | `/{basePath}/health` | `HealthPlugin` |
| Prometheus metrics | `/{basePath}/metrics` | `MetricsPlugin` |
| OpenAPI spec | `/{basePath}/openapi.json`, `/{basePath}/openapi.yaml` | `OpenApiPlugin` |
| Interactive docs | `/{basePath}/docs` | `DocsPlugin` |

The official plugins already use the same public extension model available to
third-party plugins and keep those endpoints inside the API namespace.

### Current Plugin Host Behavior

- `api.plugin(...)` registers plugin instances without running setup yet.
- Startup runs plugin setup in dependency order and uses registration order as
  the tiebreaker when there is no dependency edge.
- Host registration freezes before plugin validation runs.
- Startup failure still drains registered shutdown hooks in reverse setup order.
- All plugin routes resolve under the API instance `basePath`.
- All three public middleware slots are active; lower `order` values run
  earlier inside a slot and plugin setup order breaks ties.

See [docs/plugin_host_guide.md](docs/plugin_host_guide.md) for the current
cross-language authoring guide.

---

## Quick Start

### Dart

```dart
import 'package:modular_api/modular_api.dart';

Future<void> main() async {
  final api = ModularApi(
    basePath: '/api',
    title: 'Modular API',
    version: '1.0.0',
    metricsEnabled: true,
  );

  api.module('greetings', (m) {
    m.usecase('hello', HelloWorld.fromJson);
  });

  await api.serve(port: 8080);
}
```

### TypeScript

```typescript
import { ModularApi, ModuleBuilder } from '@macss/modular-api';

const api = new ModularApi({
  basePath: '/api',
  title: 'Modular API',
  version: '1.0.0',
  metricsEnabled: true,
});

api.module('greetings', (m: ModuleBuilder) => {
  m.usecase('hello', HelloWorld.fromJson);
});

api.serve({ port: 8080 });
```

### Python

```python
from modular_api import ModularApi

api = ModularApi(
    base_path="/api",
    title="Modular API",
    version="1.0.0",
    metrics_enabled=True,
)

api.module("greetings", lambda m: m.usecase("hello", HelloWorld))

api.serve(port=8080)
```

```bash
curl -X POST http://localhost:8080/api/greetings/hello \
  -H "Content-Type: application/json" \
  -d '{"name":"World"}'

# -> {"message": "Hello, World!"}
```

See `code/dart/modular_api/example/`, `code/ts/modular_api/example/`, and `code/py/modular_api/example/` for complete examples.

---

## Documentation

- [docs/architecture.md](docs/architecture.md) - canonical architecture specification
- [docs/application_boundary_architecture_spec.md](docs/application_boundary_architecture_spec.md) - canonical MACSS layer-separation specification around view, controller, service_client, local API, repository, and db_client
- [docs/plugin_guide.md](docs/plugin_guide.md) - definition of the reference plugin deliverable and acceptance criteria
- [docs/plugin_host_guide.md](docs/plugin_host_guide.md) - current public plugin-host and authoring guide
- [docs/service_client_model_spec.md](docs/service_client_model_spec.md) - canonical outbound service-client specification for REST, GraphQL, and future transports
- [docs/twelve_package_development_spec.md](docs/twelve_package_development_spec.md) - delivery spec for the 12 new extension packages
- [docs/extension_package_completion_checklist.md](docs/extension_package_completion_checklist.md) - working checklist for package delivery and architectural completion
- [docs/roadmap.md](docs/roadmap.md) - product roadmap focused on the API and plugin milestones

---

## License

MIT - see [LICENSE](./LICENSE)