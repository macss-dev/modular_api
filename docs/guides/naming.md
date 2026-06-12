# Naming Guide

Naming conventions for commands, classes, and files in modular_api. The rules are
identical across the TypeScript, Dart, and Python SDKs — only the file extension
changes.

## Core rule

The **command**, the **UseCase class**, and the **file** share the same root:

| Layer | Format | Example |
|---|---|---|
| Command (route segment) | `kebab-case` | `'hello-world'` |
| UseCase class | `PascalCase` | `HelloWorld` |
| File | `snake_case` | `hello_world.ts` / `.dart` / `.py` |

The command string passed to `m.usecase(command, ...)` becomes the URL segment and
the root for every related symbol. The full route is:

```
route = {basePath}/{module}/{command}
```

## Input / Output DTOs

Append `Input` and `Output` to the UseCase class name:

```ts
class HelloWorldInput extends Input { ... }
class HelloWorldOutput extends Output { ... }
class HelloWorld implements UseCase<HelloWorldInput, HelloWorldOutput> { ... }
```

## Full example

```
command:  'hello-world'
route:    POST /api/v1/greetings/hello-world

file:     hello_world.ts        (hello_world.dart, hello_world.py)
class:    HelloWorld
input:    HelloWorldInput
output:   HelloWorldOutput
schema:   greetings_hello_world_Input / greetings_hello_world_Output
```

## Why "command"?

Use cases are **commands** — explicit, validated operations that change state
(POST, PUT, PATCH, DELETE). This terminology aligns with the CQRS architecture
planned for v0.6.0:

- **Commands** — REST endpoints (use cases), write operations
- **Queries** — GraphQL plugin, read operations

See [roadmap.md](../roadmap.md) for the full CQRS vision.
