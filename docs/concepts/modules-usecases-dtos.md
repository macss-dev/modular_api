# Modules, Use Cases, and DTOs

This is the core model of modular_api, identical across the TypeScript, Dart, and
Python SDKs. A service is a set of **modules**; each module groups **use cases**;
each use case is a **command** exposed as an HTTP endpoint with typed **Input** and
**Output** DTOs.

```
HTTP Request -> ModularApi -> Module -> UseCase -> Business Logic -> Output -> HTTP Response
```

## Routing model

A use case is registered with a module name and a command:

```
route = {basePath}/{module}/{command}
```

- The **command** is `kebab-case` (`'hello-world'`). It becomes the URL segment and
  the operationId root.
- All endpoints default to **POST** (configurable per use case via the `method` option).
- The command, the UseCase class, and the file share the same root
  (`hello-world` / `HelloWorld` / `hello_world.ts`). See the
  [naming guide](../guides/naming.md).

## The UseCase contract

Every use case implements the same four-step flow:

1. `fromJson(json)` — static factory that builds the use case from the request body
   (and wires real adapters: repositories, DB clients, HTTP clients).
2. `validate()` — returns `null` when input is valid, or an error message string.
   The framework responds 400 with that message when non-null.
3. `execute()` — async business logic. Returns the Output DTO.
4. `Output.toJson()` — serialized and returned to the HTTP client with
   `Output.statusCode` (default 200).

Business logic stays pure: no request/response objects, no headers, no HTTP concerns
inside a use case. Dependencies are injected through the constructor (which is also
what makes unit testing trivial — see the [testing guide](../guides/testing.md)).

### Error handling: UseCaseException

Throw `UseCaseException` from `execute()` for structured errors. The framework maps
it to an HTTP response:

```ts
throw new UseCaseException({
  statusCode: 404,
  message: 'User not found',
  errorCode: 'USER_NOT_FOUND',
});
```

```json
{ "error": "USER_NOT_FOUND", "message": "User not found" }
```

Fields: `statusCode`, `message`, optional `errorCode`, optional `details`.

### Request-scoped logger

The framework injects a request-scoped logger (`this.logger`) into every use case.
Always use optional chaining (`this.logger?.info(...)`) so the code also works in
tests without a logger. See [observability](../guides/observability.md).

## DTOs and schema generation

Input and Output DTOs are the single source of truth for the OpenAPI schema. Each
SDK uses its idiomatic mechanism:

| SDK | Mechanism |
|---|---|
| TypeScript | `@Field` decorators (TC39 Stage 3) on class properties |
| Dart | `schemaFields` getter returning `SchemaField` entries |
| Python | Pydantic `Field()` annotations |

### TypeScript (primary)

```ts
import { Input, Output, Field } from '@macss/modular-api';

export class CreateUserInput extends Input {
  @Field.string({ description: 'User name', example: 'Ada' })
  name!: string;

  @Field.integer({ description: 'User age' })
  age!: number;
}

export class CreateUserOutput extends Output {
  @Field.string({ description: 'Generated user id' })
  userId!: string;

  get statusCode() {
    return 201;
  }
}
```

With `@Field` decorators in place, the base classes derive `toJson()`, `fromJson()`
pre-validation, and `toSchema()` automatically from the field metadata.

Available factories: `Field.string()`, `Field.integer()`, `Field.number()`,
`Field.boolean()`, `Field.array()`.

Registration requires the DTO classes so the framework can extract schemas and
pre-validate input:

```ts
m.usecase('create', CreateUser.fromJson, {
  inputClass: CreateUserInput,
  outputClass: CreateUserOutput,
  // method: 'POST' (default), summary, description optional
});
```

Critical: `@Field` is a **standard TC39 Stage 3 decorator**. The consumer project
must NOT set `experimentalDecorators: true` in any tsconfig — the legacy compilation
changes the decorator calling convention, the field metadata is never registered, and
`toJson()` fails at runtime. See [pitfalls.md](../pitfalls.md).

### Dart parity notes

Dart DTOs extend `Input`/`Output` and implement three members explicitly:

- `fromJson` factory constructor
- `toJson()` method
- `schemaFields` getter — the schema source of truth

```dart
class CreateUserInput extends Input {
  final String name;
  final int? age; // nullable = optional

  CreateUserInput({required this.name, this.age});

  factory CreateUserInput.fromJson(Map<String, dynamic> json) {
    return CreateUserInput(name: json['name'] as String, age: json['age'] as int?);
  }

  @override
  Map<String, dynamic> toJson() => {'name': name, if (age != null) 'age': age};

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.string('name', description: 'User name'),
        SchemaField.integer('age', description: 'User age', nullable: true),
      ];
}
```

Type mapping:

| Dart type | SchemaField factory | OpenAPI type |
|---|---|---|
| `int` | `SchemaField.integer()` | `integer` |
| `double` | `SchemaField.number()` | `number` |
| `String` | `SchemaField.string()` | `string` |
| `bool` | `SchemaField.boolean()` | `boolean` |
| `List<T>` | `SchemaField.array(items: ...)` | `array` |
| `T?` | any factory with `nullable: true` | excluded from `required[]` |

Manual `toSchema()` overrides still work but are deprecated; use `schemaFields`.

### Python parity notes

Python DTOs are Pydantic models — `fromJson`/`toJson` and the schema come for free:

```python
class CreateUserInput(Input):
    name: str = Field(description="User name")
    age: int | None = Field(default=None, description="User age")
```

Output status uses the `status_code` property; the exception is `UseCaseException`
with `status_code`, `message`, `error_code` keyword arguments (snake_case throughout).

## Module registration

```ts
api
  .module('users', (m) => {
    m.usecase('create', CreateUser.fromJson, { inputClass: CreateUserInput, outputClass: CreateUserOutput });
    m.usecase('get', GetUser.fromJson, { method: 'GET', inputClass: GetUserInput, outputClass: GetUserOutput });
  })
  .module('products', buildProductsModule);
```

This produces `POST {basePath}/users/create`, `GET {basePath}/users/get`, etc., and
each appears automatically in `/docs` and `/openapi.json`.

## Related

- [Request lifecycle](request-lifecycle.md) — where module routes sit in the pipeline
- [Plugin host](plugin-host.md) — extending the API beyond JSON use cases
- [Naming guide](../guides/naming.md) — command/class/file conventions
