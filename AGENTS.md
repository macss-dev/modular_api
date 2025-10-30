## Framework Overview

`modular_api` is a Dart/Flutter framework for building use-case-centric REST APIs on top of Shelf. It follows a clean architecture pattern where business logic is separated from HTTP concerns.

**Core Concepts:**
1. **UseCase** — A class encapsulating a single business operation
2. **Input** — DTO representing request data
3. **Output** — DTO representing response data
4. **Module** — Logical grouping of related use cases
5. **ModularApi** — Main class that orchestrates routing and middleware

---

## Quick Architecture Summary

```
HTTP Request → ModularApi → Module → UseCase → Business Logic → Output → HTTP Response
                                ↓
                             Input DTO (validated)
```

**Key Points for AI Agents:**
- Every endpoint is a UseCase
- UseCases receive Input DTOs and return Output DTOs
- All endpoints are POST by default
- Automatic OpenAPI/Swagger documentation generation
- Built-in middlewares: CORS, API Key authentication
- Automatic health endpoint at `/health`

---

## When to Use This Framework

Use `modular_api` when users need to:
- Build REST APIs in Dart/Flutter
- Implement clean architecture with use cases
- Generate automatic API documentation (OpenAPI/Swagger)
- Have testable, modular server code
- Separate business logic from HTTP concerns

**Do NOT use** for:
- GraphQL APIs (use different framework)
- WebSocket-only servers
- Simple static file servers
- Frontend applications

---

## Implementation Workflow

When a user asks to create an API or use case, follow this sequence:

### Step 1: Create Input and Output DTOs
**Reference:** [USECASE_DTO_GUIDE.md](./USECASE_DTO_GUIDE.md)

Each DTO must:
- Extend `Input` or `Output` base class
- Have all properties as `final`
- Implement `fromJson` factory constructor
- Override `toJson()` method
- Override `toSchema()` method for OpenAPI documentation

**Critical:** The `toSchema()` method must accurately represent all class properties using OpenAPI specification types.

**Type Mapping (Dart → OpenAPI):**
- `int` → `{'type': 'integer'}`
- `double` → `{'type': 'number', 'format': 'double'}`
- `String` → `{'type': 'string'}`
- `bool` → `{'type': 'boolean'}`
- `DateTime` → `{'type': 'string', 'format': 'date-time'}`
- `List<T>` → `{'type': 'array', 'items': {...}}`
- Custom object → `{'type': 'object', 'properties': {...}}`

### Step 2: Implement the UseCase
**Reference:** [USECASE_IMPLEMENTATION_GUIDE.md](./USECASE_IMPLEMENTATION_GUIDE.md)

Each UseCase must:
- Extend `UseCase<InputType, OutputType>`
- Call `super(input)` in constructor
- Implement static `fromJson(Map<String, dynamic> json)` factory
- Override `execute()` method returning `Future<OutputType>`
- Keep business logic pure (no HTTP concerns)

**Structure:**
```dart
class MyUseCase extends UseCase<MyInput, MyOutput> {
  MyUseCase(super.input);
  
  static MyUseCase fromJson(Map<String, dynamic> json) {
    return MyUseCase(MyInput.fromJson(json));
  }
  
  @override
  Future<MyOutput> execute() async {
    // Business logic here
    return MyOutput(/* data */);
  }
}
```

### Step 3: Create Module Builder

Create a builder function that encapsulates all use cases for a module:

```dart
void buildMyModule(ModuleBuilder m) {
  m.usecase('usecase-name', MyUseCase.fromJson);
  m.usecase('another-usecase', AnotherUseCase.fromJson);
  // Add more use cases as needed
}
```

### Step 4: Register Modules in ModularApi

```dart
final api = ModularApi(basePath: '/api');

// Register modules using their builders
api.module('module1', buildModule1);
api.module('module2', buildModule2);
api.module('users', buildUsersModule);

await api.serve(port: 8080);
```

This creates endpoints like:
- `POST /api/module1/usecase-name`
- `POST /api/module2/usecase-name`
- `POST /api/users/create`

---

## Common User Requests and How to Handle Them

### Request: "Create an API endpoint to [do something]"

**Actions:**
1. Identify the operation name (e.g., "calculate sum", "create user")
2. Define Input DTO with required fields
3. Define Output DTO with result fields
4. Implement UseCase with business logic
5. Create or update module builder function to register the UseCase
6. Show registration code in main() using module builder
7. Provide example curl request

**Example Response Structure:**
- Show Input DTO implementation
- Show Output DTO implementation
- Show UseCase implementation
- Show module builder function (or update existing one)
- Show registration in ModularApi using the builder
- Provide test example using `useCaseTestHandler`

### Request: "Add validation to my use case"

**Actions:**
1. Add validation logic in `execute()` method
2. Throw `ArgumentError` or custom exceptions for validation failures
3. Framework automatically converts exceptions to HTTP 500 responses
4. Show updated `execute()` method with validation

### Request: "Connect to a database"

**Actions:**
1. Show how to inject `DbClient` in UseCase constructor
2. Implement `fromJson` to create/inject DB client
3. Show SQL query execution in `execute()` method
4. Handle empty results with exceptions
5. Parse result rows into Output DTO

**Built-in DB Support:**
- `DbClient` interface available
- ODBC support for SQL Server and Oracle
- DSN-based connections

### Request: "Add authentication"

**Actions:**
1. Show `apiKey()` middleware usage
2. Explain API key is read from `API_KEY` environment variable
3. Show how to use `Env.getString('API_KEY')`
4. Add middleware before serve: `api.use(apiKey())`

### Request: "Enable CORS"

**Actions:**
1. Show `cors()` middleware usage
2. Add before serve: `api.use(cors())`

### Request: "How do I test this?"

**Actions:**
1. Show `useCaseTestHandler` helper
2. Provide complete test example with `package:test`
3. Show how to test validation errors
4. Explain testing without HTTP server (unit test level)

---

## Code Generation Guidelines for AI Agents

### When generating DTOs:

1. **Always include all three methods:** `fromJson`, `toJson`, `toSchema`
2. **toSchema must match class properties exactly**
3. **Use proper type mapping** (see Type Mapping section)
4. **Mark optional fields with `?` in Dart and exclude from `required` array in schema**
5. **Add descriptions** to all properties in `toSchema` for better documentation

### When generating UseCases:

1. **Keep execute() method focused** — single responsibility
2. **Inject dependencies** via constructor, not create inside execute()
3. **Use meaningful variable names** for clarity
4. **Add validation** before business logic
5. **Throw descriptive exceptions** for errors
6. **Return properly constructed Output DTO**

### When showing registration:

1. **Show module builder function** — Encapsulate use cases in a builder
2. **Show complete main() function** with ModularApi setup registering builders
3. **Include port and base path** configuration
4. **Show how to access Swagger docs** at `/docs`
5. **Mention health endpoint** at `/health`
6. **Use meaningful module and usecase names** (kebab-case preferred)
7. **Keep builders in separate files** for better organization

---

## Environment Variables (Env class)

The framework provides `Env` utility for environment variables:

**Behavior (v0.0.4+):**
1. If `.env` file exists → read from it
2. If `.env` not found → fallback to `Platform.environment`
3. If key not found in either → throw `EnvKeyNotFoundException`

**Methods:**
- `Env.getString(key)` — Get string value (removes quotes if present)
- `Env.getInt(key)` — Get integer value (throws `EnvParseException` if invalid)
- `Env.init()` — Initialize and load .env file (optional, called automatically)

**Usage Example:**
```dart
final apiKey = Env.getString('API_KEY');
final port = Env.getInt('PORT');
```

---

## Automatic Features

When helping users, inform them about these automatic features:

1. **Health Endpoint** — `GET /health` responds with `ok` (no registration needed)
2. **OpenAPI Documentation** — Auto-generated from DTOs' `toSchema()` methods
3. **Swagger UI** — Available at `/docs` endpoint
4. **Error Handling** — Exceptions automatically converted to HTTP 500 responses
5. **JSON Parsing** — Automatic for Input DTOs via `fromJson`
6. **JSON Serialization** — Automatic for Output DTOs via `toJson`

---

## File Organization Recommendations

Suggest this structure for larger projects:

```
lib/
  modules/
    module1/
      usecases/
        usecase_1.dart
        usecase_2.dart
      repositories/
        repository.dart
      module1_builder.dart      # Builder function for module1
    module2/
      usecases/
        usecase_3.dart
        usecase_4.dart
      module2_builder.dart      # Builder function for module2
  db/
    db_client.dart
bin/
  main.dart                     # Imports all module builders
test/
  module1/
    usecase_1_test.dart
```

**Module Builder Pattern:**

Each module should have its own builder file (e.g., `module1_builder.dart`):

```dart
import 'package:modular_api/modular_api.dart';
import 'usecases/usecase_1.dart';
import 'usecases/usecase_2.dart';

void buildModule1(ModuleBuilder m) {
  m.usecase('usecase-1', UseCase1.fromJson);
  m.usecase('usecase-2', UseCase2.fromJson);
}
```

Then in `main.dart`:

```dart
import 'package:modular_api/modular_api.dart';
import 'lib/modules/module1/module1_builder.dart';
import 'lib/modules/module2/module2_builder.dart';

Future<void> main() async {
  final api = ModularApi(basePath: '/api');
  
  api.module('module1', buildModule1);
  api.module('module2', buildModule2);
  
  await api.serve(port: 8080);
}
```

---

## Testing Pattern

Always suggest this testing pattern using `useCaseTestHandler`:

```dart
import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';
import 'dart:convert';

void main() {
  group('MyUseCase', () {
    test('should return expected output', () async {
      final input = {'field': 'value'};
      final handler = useCaseTestHandler(MyUseCase.fromJson);
      
      final response = await handler(input);
      
      expect(response.statusCode, equals(200));
      final body = jsonDecode(await response.readAsString());
      expect(body['result'], equals('expected'));
    });
  });
}
```

---

## Common Mistakes to Avoid

When generating code, ensure you avoid these common mistakes:

1. ❌ **Forgetting `toSchema()`** — Required for OpenAPI docs
2. ❌ **Mismatched types in `toSchema()`** — Must match Dart types
3. ❌ **Not calling `super(input)`** in UseCase constructor
4. ❌ **Missing `static fromJson`** in UseCase
5. ❌ **Creating dependencies inside execute()** — Inject via constructor
6. ❌ **Accessing HTTP request/response** in UseCase — Keep it pure
7. ❌ **Not marking all DTO properties as `final`**
8. ❌ **Forgetting to override `toJson()` and `toSchema()`**
9. ❌ **Using mutable properties** in DTOs
10. ❌ **Not handling null/empty results** from database queries

---

## Error Messages and Troubleshooting

### Common Error: "Missing fromJson factory"
**Solution:** Add `static MyUseCase fromJson(Map<String, dynamic> json)` to UseCase class

### Common Error: "toSchema not implemented"
**Solution:** Override `toSchema()` method in Input/Output DTOs

### Common Error: "EnvKeyNotFoundException"
**Solution:** 
- Add key to `.env` file, OR
- Set as system environment variable, OR
- Check key name spelling

### Common Error: "Type mismatch in fromJson"
**Solution:** Ensure proper type casting: `json['field'] as Type` or `(json['field'] as num).toDouble()`

---

## Key Differences from Other Frameworks

Help users understand these differences:

| Feature | modular_api | Express.js | Spring Boot |
|---------|-------------|------------|-------------|
| Language | Dart | JavaScript | Java |
| Pattern | Use-case centric | Route-based | Controller-based |
| HTTP Method | POST (default) | Any | Any |
| Validation | Manual in execute() | Middleware | Annotations |
| DI | Manual injection | Built-in | Built-in |
| Testing | useCaseTestHandler | Supertest | MockMvc |

---

## Dependencies to Import

When generating code, include these imports:

```dart
import 'package:modular_api/modular_api.dart'; // Always needed
import 'dart:convert'; // For jsonDecode/jsonEncode
import 'package:test/test.dart'; // For testing
import 'package:http/http.dart' as http; // For HTTP clients (if needed)
```

---

## Complete Minimal Example

When users ask for a complete example, provide this:

```dart
// Input DTO
class HelloInput extends Input {
  final String name;
  
  HelloInput({required this.name});
  
  factory HelloInput.fromJson(Map<String, dynamic> json) {
    return HelloInput(name: json['name'] as String);
  }
  
  @override
  Map<String, dynamic> toJson() => {'name': name};
  
  @override
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'name': {'type': 'string', 'description': 'User name'},
      },
      'required': ['name'],
    };
  }
}

// Output DTO
class HelloOutput extends Output {
  final String message;
  
  HelloOutput({required this.message});
  
  factory HelloOutput.fromJson(Map<String, dynamic> json) {
    return HelloOutput(message: json['message'] as String);
  }
  
  @override
  Map<String, dynamic> toJson() => {'message': message};
  
  @override
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'message': {'type': 'string', 'description': 'Greeting message'},
      },
      'required': ['message'],
    };
  }
}

// UseCase
class SayHello extends UseCase<HelloInput, HelloOutput> {
  SayHello(super.input);
  
  static SayHello fromJson(Map<String, dynamic> json) {
    return SayHello(HelloInput.fromJson(json));
  }
  
  @override
  Future<HelloOutput> execute() async {
    return HelloOutput(message: 'Hello, ${input.name}!');
  }
}

// Main
Future<void> main() async {
  final api = ModularApi(basePath: '/api');
  
  api.module('greetings', (m) {
    m.usecase('hello', SayHello.fromJson);
  });
  
  await api.serve(port: 8080);
  print('API running at http://localhost:8080');
  print('Try: curl -X POST http://localhost:8080/api/greetings/hello -H "Content-Type: application/json" -d "{\\"name\\":\\"World\\"}"');
}
```

**Note:** For projects with multiple use cases, prefer creating separate module builder functions:

```dart
// greetings_builder.dart
void buildGreetingsModule(ModuleBuilder m) {
  m.usecase('hello', SayHello.fromJson);
  m.usecase('goodbye', SayGoodbye.fromJson);
}

// main.dart
Future<void> main() async {
  final api = ModularApi(basePath: '/api');
  
  api.module('greetings', buildGreetingsModule);
  api.module('users', buildUsersModule);
  
  await api.serve(port: 8080);
}
```

---

## Quick Reference Commands

**Install package:**
```bash
dart pub add modular_api
```

**Run server:**
```bash
dart run bin/main.dart
```

**Run tests:**
```bash
dart test
```

**Compile to executable:**
```bash
dart compile exe bin/main.dart -o build/server
```

---

## Additional Resources

- [USECASE_DTO_GUIDE.md](./USECASE_DTO_GUIDE.md) — Comprehensive guide for creating Input/Output DTOs
- [USECASE_IMPLEMENTATION_GUIDE.md](./USECASE_IMPLEMENTATION_GUIDE.md) — Complete guide for implementing UseCases
- [README.md](./README.md) — User-facing documentation with installation and quick start
- `template/` folder — Full example project with multiple modules
- `example/` folder — Minimal runnable example

---

## Version-Specific Features

### v0.0.4+ (current)
- Env fallback to Platform.environment when .env is missing
- EnvKeyNotFoundException thrown when key not found

### v0.0.3+
- Automatic GET /health endpoint

### v0.0.2+
- Automatic OpenAPI initialization
- Renamed middlewares

### v0.0.1
- Initial release with core features

---

## AI Agent Guidelines Summary

When assisting users with `modular_api`:

1. ✅ **Always generate complete code** — Include all three DTO methods, full UseCase, and registration
2. ✅ **Reference the guides** — Point users to USECASE_DTO_GUIDE.md and USECASE_IMPLEMENTATION_GUIDE.md for detailed explanations
3. ✅ **Follow the pattern** — Input → UseCase → Output, no HTTP concerns in business logic
4. ✅ **Include tests** — Show useCaseTestHandler examples
5. ✅ **Suggest file organization** — Especially for projects with multiple modules
6. ✅ **Explain automatic features** — Health endpoint, OpenAPI docs, error handling
7. ✅ **Validate schemas match DTOs** — Ensure toSchema() accurately represents class properties
8. ✅ **Use dependency injection** — Never create dependencies inside execute()
9. ✅ **Provide curl examples** — Help users test their endpoints immediately
10. ✅ **Keep it simple** — Start with minimal examples, add complexity only when needed

---

**This framework prioritizes clean architecture, testability, and separation of concerns. Always guide users toward these principles when generating code.**
