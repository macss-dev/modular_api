# Getting Started — Python

The Python SDK builds modular APIs on top of Starlette.

## Installation

```bash
pip install macss-modular-api
```

With Uvicorn for `api.serve()`:

```bash
pip install macss-modular-api[serve]
```

## Minimal module and use case

```python
# usecases/hello_world.py
from modular_api import Input, Output, UseCase, UseCaseException
from pydantic import Field


class HelloWorldInput(Input):
    name: str = Field(description="Name to greet")


class HelloWorldOutput(Output):
    message: str = Field(description="Greeting message")


class HelloWorld(UseCase[HelloWorldInput, HelloWorldOutput]):
    def validate(self) -> str | None:
        return None if self.input.name else "name is required"

    async def execute(self) -> HelloWorldOutput:
        return HelloWorldOutput(message=f"Hello, {self.input.name}!")
```

```python
# main.py
from modular_api import ModularApi, ModuleBuilder
from usecases.hello_world import HelloWorld


def build_greetings_module(m: ModuleBuilder) -> None:
    m.usecase("hello-world", HelloWorld)


api = ModularApi(base_path="/api/v1", title="My Service", version="1.0.0")
api.module("greetings", build_greetings_module)
api.serve(port=8080)
```

```bash
curl -X POST http://localhost:8080/api/v1/greetings/hello-world \
  -H "Content-Type: application/json" \
  -d '{"name":"World"}'
# {"message":"Hello, World!"}
```

Operational endpoints (all under the configured `base_path`):

| Endpoint | URL |
|---|---|
| Scalar docs | `http://localhost:8080/api/v1/docs` |
| Health | `http://localhost:8080/api/v1/health` |
| OpenAPI spec | `http://localhost:8080/api/v1/openapi.json` (also `.yaml`) |
| Metrics (opt-in) | `http://localhost:8080/api/v1/metrics` |

For deployment behind an existing ASGI server, use `app = api.build()` instead of
`api.serve()`.

## Next steps

- [Modules, use cases, and DTOs](../concepts/modules-usecases-dtos.md) — the core model
- [Request lifecycle](../concepts/request-lifecycle.md) — middleware and routing order
- [Testing](../guides/testing.md) — unit tests with constructor-injected fakes
- [Observability](../guides/observability.md) — metrics, structured logs, trace ids
- [Pitfalls](../pitfalls.md) — known traps reported by real consumers
