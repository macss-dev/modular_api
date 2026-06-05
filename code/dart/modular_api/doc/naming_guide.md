# Naming Guide

Naming conventions for commands, classes, and files in `modular_api`.

---

## Core Rule

The **command**, the **UseCase class**, and the **file** share the same root:

| Layer | Format | Example |
|---|---|---|
| Command (route segment) | `kebab-case` | `'hello-world'` |
| UseCase class | `PascalCase` | `HelloWorld` |
| File | `snake_case` | `hello_world.dart` |

The command string passed to `m.usecase(command, ...)` becomes the URL segment
(`/module/command`) and the root for every related symbol.

---

## Input / Output DTOs

Append `Input` and `Output` to the UseCase class name:

```dart
class HelloWorldInput extends Input { ... }
class HelloWorldOutput extends Output { ... }
class HelloWorld implements UseCase<HelloWorldInput, HelloWorldOutput> { ... }
```

---

## Full Example

```
command:  'hello-world'
route:    POST /api/v1/greetings/hello-world

file:     hello_world.dart
class:    HelloWorld
input:    HelloWorldInput
output:   HelloWorldOutput
schema:   greetings_hello_world_Input / greetings_hello_world_Output
```

---

## Why "Command"?

Use cases are **commands** — explicit, validated operations that change state
(POST, PUT, PATCH, DELETE). This terminology aligns with the CQRS architecture
planned for v0.6.0, where:

- **Commands** → REST endpoints (use cases) — write operations
- **Queries** → GraphQL plugin — read operations

See [roadmap.md](../../docs/roadmap.md) for the full CQRS vision.
