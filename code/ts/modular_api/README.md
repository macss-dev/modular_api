# modular-api

Use-case centric toolkit for building modular APIs with Express.  
Define `UseCase` classes (input → validate → execute → output), connect them to HTTP routes, and get automatic Swagger/OpenAPI documentation.

> Also available in **Dart**: [modular_api](https://pub.dev/packages/modular_api) · **Python**: [macss-modular-api](https://pypi.org/project/macss-modular-api/)

---

## Quick start

```ts
import { ModularApi, ModuleBuilder } from '@macss/modular-api';

// ─── Module builder (separate file in real projects) ──────────
function buildGreetingsModule(m: ModuleBuilder): void {
  m.usecase('hello', HelloWorld.fromJson);
}

// ─── Server ───────────────────────────────────────────────────
const api = new ModularApi({ basePath: '/api' });

api.module('greetings', buildGreetingsModule);

api.serve({ port: 8080 });
```

```bash
curl -X POST http://localhost:8080/api/greetings/hello \
  -H "Content-Type: application/json" \
  -d '{"name":"World"}'
```

```json
{ "message": "Hello, World!" }
```

**Docs** → `http://localhost:8080/api/docs`
**Health** → `http://localhost:8080/api/health`
**OpenAPI JSON** → `http://localhost:8080/api/openapi.json` _(also /api/openapi.yaml)_
**Metrics** → `http://localhost:8080/api/metrics` _(opt-in)_

See `example/example.ts` for the full implementation including Input, Output, UseCase with `validate()`, and the builder.

---

## Features

- `UseCase<I, O>` — pure business logic, no HTTP concerns
- `Input` / `Output` — DTOs with automatic OpenAPI schema generation via `@Field` decorators
- `Output.statusCode` — custom HTTP status codes per response
- `UseCaseException` — structured error handling (status code, message, error code, details)
- `ModularApi` + `ModuleBuilder` — module registration and routing
- Constructor-based unit testing with fake dependency injection
- `cors()` middleware — built-in CORS support
- All public endpoints resolve under the configured `basePath`.
- Swagger UI at `/{basePath}/docs` — auto-generated from registered use cases
- OpenAPI spec at `/{basePath}/openapi.json` and `/{basePath}/openapi.yaml` — raw spec download
- Health check at `GET /{basePath}/health` — [IETF Health Check Response Format](doc/health_check_guide.md)
- Prometheus metrics at `GET /{basePath}/metrics` — [Prometheus exposition format](doc/metrics_guide.md)
- Structured JSON logging — Loki/Grafana compatible, [request-scoped with trace_id](doc/logger_guide.md)
- All endpoints default to `POST` (configurable per use case)
- Full TypeScript declarations (`.d.ts`) included

---

## Plugin host

The public plugin contract is available from the package exports and is already
used by the official health, metrics, OpenAPI, and docs plugins.

Current lifecycle behavior:

- `api.plugin(...)` registers a plugin instance without running setup yet
- `setup(host)` runs during `serve()` in dependency order
- `validate(host)` runs after registration freeze and can abort startup
- `shutdown()` runs in reverse setup order on normal shutdown and on partial
  startup rollback
- plugin routes always resolve under the configured `basePath`
- all three public middleware slots are active with deterministic ordering

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
      // Optional OpenAPI Operation object — when present, the official
      // OpenApiPlugin merges the route into /openapi.json and /docs (ADR-0003).
      openapi: {
        summary: 'Hello from a plugin route',
        responses: { '200': { description: 'OK' } },
      },
      handler: () => ({
        status: 200,
        body: { ok: true, basePath: host.metadata().basePath },
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

---

## Installation

```bash
npm install @macss/modular-api
```

If you use `SqlServerMetadataReader` for SQL Server introspection, install `mssql` explicitly:

```bash
npm install @macss/modular-api mssql
```

---

## Error handling

```ts
async execute() {
  const user = await repository.findById(this.input.userId);
  if (!user) {
    throw new UseCaseException({
      statusCode: 404,
      message: 'User not found',
      errorCode: 'USER_NOT_FOUND',
    });
  }
  return new GetUserOutput(user);
}
```

```json
{ "error": "USER_NOT_FOUND", "message": "User not found" }
```

---

## Testing

Write true unit tests by injecting fake dependencies directly through the constructor.
No HTTP server or real infrastructure needed.

```ts
import { describe, it, expect, beforeEach } from 'vitest';
import { UseCaseException } from '@macss/modular-api';

// ─── Fake ────────────────────────────────────────────────────
class FakeGreetingRepository implements GreetingRepository {
  saved: string[] = [];

  async save(name: string): Promise<void> {
    this.saved.push(name);
  }
}

// ─── Tests ───────────────────────────────────────────────────
describe('SayHello', () => {
  let fakeRepo: FakeGreetingRepository;

  beforeEach(() => {
    fakeRepo = new FakeGreetingRepository();
  });

  it('greets correctly', async () => {
    const usecase = new SayHello(new SayHelloInput('World'), { repository: fakeRepo });

    expect(usecase.validate()).toBeNull();

    const output = await usecase.execute();

    expect(output.message).toBe('Hello, World!');
    expect(fakeRepo.saved).toContain('World');
  });

  it('rejects empty name', () => {
    const usecase = new SayHello(new SayHelloInput(''), { repository: fakeRepo });

    expect(usecase.validate()).not.toBeNull();
  });

  it('throws UseCaseException when repo fails', async () => {
    const failingRepo = {
      save: async () => {
        throw new Error('DB error');
      },
    };

    const usecase = new SayHello(new SayHelloInput('World'), { repository: failingRepo });

    await expect(usecase.execute()).rejects.toThrow(UseCaseException);
  });
});
```

For integration tests against real infrastructure, use `UseCase.fromJson()` directly
(no helper wrapper needed):

```ts
it('integration — end to end with real DB', async () => {
  const usecase = SayHello.fromJson({ name: 'World' });
  const output = await usecase.execute();
  expect(output.message).toBe('Hello, World!');
});
```

See [doc/testing_guide.md](doc/testing_guide.md) for the full guide.

---

## Architecture

```
HTTP Request → ModularApi → Module → UseCase → Business Logic → Output → HTTP Response
```

- **UseCase layer** — pure logic, independent of HTTP
- **HTTP adapter** — turns a UseCase into an Express RequestHandler
- **Middlewares** — cross-cutting concerns (CORS, logging)
- **Swagger UI** — documentation served automatically

---

## License

MIT © [ccisne.dev](https://ccisne.dev)
