# Getting Started — TypeScript

The TypeScript SDK builds modular APIs on top of Express.

## Installation

```bash
npm install @macss/modular-api
```

If you use `SqlServerMetadataReader` for SQL Server introspection, install `mssql` explicitly:

```bash
npm install @macss/modular-api mssql
```

Important: do not enable `experimentalDecorators` in any `tsconfig.json` of your project.
The `@Field` decorators are standard TC39 Stage 3 decorators; the legacy flag silently breaks
schema metadata registration. See [pitfalls.md](../pitfalls.md).

## Minimal module and use case

```ts
// usecases/hello_world.ts
import { Input, Output, UseCase, Field, ModularLogger } from '@macss/modular-api';

export class HelloWorldInput extends Input {
  @Field.string({ description: 'Name to greet', example: 'World' })
  name!: string;
}

export class HelloWorldOutput extends Output {
  @Field.string({ description: 'Greeting message', example: 'Hello, World!' })
  message!: string;
}

export class HelloWorld implements UseCase<HelloWorldInput, HelloWorldOutput> {
  readonly input: HelloWorldInput;
  logger?: ModularLogger;

  constructor(input: HelloWorldInput) {
    this.input = input;
  }

  static fromJson(json: Record<string, unknown>): HelloWorld {
    const input = new HelloWorldInput();
    input.name = json['name'] as string;
    return new HelloWorld(input);
  }

  validate(): string | null {
    return this.input.name ? null : 'name is required';
  }

  async execute(): Promise<HelloWorldOutput> {
    const output = new HelloWorldOutput();
    output.message = `Hello, ${this.input.name}!`;
    return output;
  }
}
```

```ts
// main.ts
import { ModularApi, ModuleBuilder } from '@macss/modular-api';
import { HelloWorld, HelloWorldInput, HelloWorldOutput } from './usecases/hello_world';

function buildGreetingsModule(m: ModuleBuilder): void {
  m.usecase('hello-world', HelloWorld.fromJson, {
    inputClass: HelloWorldInput,
    outputClass: HelloWorldOutput,
  });
}

const api = new ModularApi({ basePath: '/api/v1', title: 'My Service', version: '1.0.0' });
api.module('greetings', buildGreetingsModule);
await api.serve({ port: 8080 });
```

```bash
curl -X POST http://localhost:8080/api/v1/greetings/hello-world \
  -H "Content-Type: application/json" \
  -d '{"name":"World"}'
# {"message":"Hello, World!"}
```

Operational endpoints (all under the configured `basePath`):

| Endpoint | URL |
|---|---|
| Swagger UI | `http://localhost:8080/api/v1/docs` |
| Health | `http://localhost:8080/api/v1/health` |
| OpenAPI spec | `http://localhost:8080/api/v1/openapi.json` (also `.yaml`) |
| Metrics (opt-in) | `http://localhost:8080/api/v1/metrics` |

## Next steps

- [Modules, use cases, and DTOs](../concepts/modules-usecases-dtos.md) — the core model
- [Request lifecycle](../concepts/request-lifecycle.md) — middleware and routing order
- [Testing](../guides/testing.md) — unit tests with constructor-injected fakes
- [Observability](../guides/observability.md) — metrics, structured logs, trace ids
- [Pitfalls](../pitfalls.md) — known traps reported by real consumers
