# Getting Started — Dart

The Dart SDK builds modular APIs on top of Shelf.

## Installation

```yaml
dependencies:
  modular_api: ^0.5.0
```

```bash
dart pub add modular_api
```

## Minimal module and use case

```dart
// lib/usecases/hello_world.dart
import 'package:modular_api/modular_api.dart';

class HelloWorldInput extends Input {
  final String name;

  HelloWorldInput({required this.name});

  factory HelloWorldInput.fromJson(Map<String, dynamic> json) {
    return HelloWorldInput(name: json['name'] as String);
  }

  @override
  Map<String, dynamic> toJson() => {'name': name};

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.string('name', description: 'Name to greet'),
      ];
}

class HelloWorldOutput extends Output {
  final String message;

  HelloWorldOutput({required this.message});

  factory HelloWorldOutput.fromJson(Map<String, dynamic> json) {
    return HelloWorldOutput(message: json['message'] as String);
  }

  @override
  int get statusCode => 200;

  @override
  Map<String, dynamic> toJson() => {'message': message};

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.string('message', description: 'Greeting message'),
      ];
}

class HelloWorld extends UseCase<HelloWorldInput, HelloWorldOutput> {
  HelloWorld(super.input);

  static HelloWorld fromJson(Map<String, dynamic> json) {
    return HelloWorld(HelloWorldInput.fromJson(json));
  }

  @override
  String? validate() => input.name.isEmpty ? 'name is required' : null;

  @override
  Future<HelloWorldOutput> execute() async {
    return HelloWorldOutput(message: 'Hello, ${input.name}!');
  }
}
```

```dart
// bin/main.dart
import 'package:modular_api/modular_api.dart';

void buildGreetingsModule(ModuleBuilder m) {
  m.usecase('hello-world', HelloWorld.fromJson);
}

Future<void> main() async {
  final api = ModularApi(basePath: '/api/v1', title: 'My Service', version: '1.0.0');
  api.module('greetings', buildGreetingsModule);
  await api.serve(port: 8080);
}
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

## Compile to executable

```bash
dart compile exe bin/main.dart -o build/server
```

## Next steps

- [Modules, use cases, and DTOs](../concepts/modules-usecases-dtos.md) — the core model
- [Request lifecycle](../concepts/request-lifecycle.md) — middleware and routing order
- [Testing](../guides/testing.md) — unit tests with constructor-injected fakes
- [Observability](../guides/observability.md) — metrics, structured logs, trace ids
- [Pitfalls](../pitfalls.md) — known traps reported by real consumers
