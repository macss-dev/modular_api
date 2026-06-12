# modular-api

Use-case-centric toolkit for building modular APIs with Starlette.  
Define `UseCase` classes (input → validate → execute → output), connect them to HTTP routes, and get automatic OpenAPI documentation.

> Also available in **Dart**: [modular_api](https://pub.dev/packages/modular_api) · **TypeScript**: [@macss/modular-api](https://www.npmjs.com/package/@macss/modular-api)

---

## Quick start

```python
from modular_api import ModularApi, ModuleBuilder

# ─── Module builder (separate file in real projects) ──────────
def build_greetings_module(m: ModuleBuilder) -> None:
    m.usecase("hello", HelloWorld)

# ─── Server ───────────────────────────────────────────────────
api = ModularApi(base_path="/api")

api.module("greetings", build_greetings_module)

api.serve(port=8080)
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
**OpenAPI JSON** → `http://localhost:8080/api/openapi.json` *(also /api/openapi.yaml)*
**Metrics** → `http://localhost:8080/api/metrics` *(opt-in)*

See `example/example.py` for the full implementation including Input, Output, UseCase with `validate()`, and the builder.

---

## Features

- `UseCase[I, O]` — pure business logic, no HTTP concerns
- `Input` / `Output` — DTOs with automatic OpenAPI schema generation via Pydantic `Field()`
- `Output.status_code` — custom HTTP status codes per response
- `UseCaseException` — structured error handling (status_code, message, error_code, details)
- `ModularApi` + `ModuleBuilder` — module registration and routing
- Constructor-based unit testing with fake dependency injection
- `cors_middleware` — built-in CORS support
- All public endpoints resolve under the configured `base_path`.
- Swagger UI at `/{basePath}/docs` — auto-generated from registered use cases
- OpenAPI spec at `/{basePath}/openapi.json` and `/{basePath}/openapi.yaml` — raw spec download
- Health check at `GET /{basePath}/health` — [IETF Health Check Response Format](doc/health_check_guide.md)
- Prometheus metrics at `GET /{basePath}/metrics` — [Prometheus exposition format](doc/metrics_guide.md)
- Structured JSON logging — Loki/Grafana compatible, [request-scoped with trace_id](doc/logger_guide.md)
- All endpoints default to `POST` (configurable per use case)
- Full type annotations with `py.typed` marker (PEP 561)

---

## Plugin host

The public plugin contract is available from the package exports and is already
used by the official health, metrics, OpenAPI, and docs plugins.

Current lifecycle behavior:

- `api.plugin(...)` registers a plugin instance without running setup yet
- `setup(host)` runs during `build()` in dependency order
- `validate(host)` runs after registration freeze and can abort startup
- `shutdown()` runs in reverse setup order on normal shutdown and on partial
  startup rollback
- plugin routes always resolve under the configured `base_path`
- all three public middleware slots are active with deterministic ordering

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
                # Optional OpenAPI Operation object — when present, the official
                # OpenApiPlugin merges the route into /openapi.json and /docs (ADR-0003).
                openapi={
                    "summary": "Hello from a plugin route",
                    "responses": {"200": {"description": "OK"}},
                },
                handler=lambda _: {
                    "status": 200,
                    "body": {"ok": True, "basePath": host.metadata().base_path},
                },
            )
        )

    def validate(self, host: PluginHost):
        return []


api = ModularApi(base_path="/api")
api.plugin(HelloPlugin())
app = api.build()
```

---

## Installation

```bash
pip install macss-modular-api
```

With Uvicorn for `api.serve()`:

```bash
pip install macss-modular-api[serve]
```

---

## Error handling

```python
async def execute(self) -> FoundUserOutput:
    user = await repository.find_by_id(self.input.user_id)
    if not user:
        raise UseCaseException(
            status_code=404,
            message="User not found",
            error_code="USER_NOT_FOUND",
        )
    return FoundUserOutput(name=user.name)
```

---

## Testing

```python
async def test_hello_world():
    usecase = HelloWorld(HelloInput(name="World"))
    error = usecase.validate()
    assert error is None

    output = await usecase.execute()
    assert output.message == "Hello, World!"
```

See [doc/testing_guide.md](doc/testing_guide.md) for the full testing guide.

---

## License

MIT — see [LICENSE](LICENSE).
