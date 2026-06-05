# modular_api - AI Agent Guide

Quick reference guide for AI assistants working with `modular_api` framework.

---

## Framework Overview

`modular_api` is a Dart/Flutter framework for building **use-case-centric REST APIs** on top of Shelf following clean architecture.

### Core Architecture

```
HTTP Request → ModularApi → Module → UseCase → Business Logic → Output → HTTP Response
                                ↓
                             Input DTO (validated)
```

**Key Components:**
- **UseCase** — Single business operation (pure logic, no HTTP concerns)
- **Input** — Request DTO with validation
- **Output** — Response DTO
- **Module** — Logical grouping of related use cases
- **ModularApi** — Main orchestrator for routing and middleware

**Default Behavior:**
- All endpoints are POST by default
- Automatic OpenAPI/Swagger documentation at `/docs`
- Automatic health check at `GET /health`
- Built-in middlewares: CORS, API Key authentication

---

## When to Use

✅ **Use `modular_api` for:**
- REST APIs in Dart/Flutter
- Clean architecture with use cases
- Automatic API documentation
- Testable, modular server code
- Separation of business logic from HTTP

❌ **Don't use for:**
- GraphQL APIs
- WebSocket-only servers
- Simple static file servers
- Frontend applications

---

## Quick Implementation Guide

### 1. Create DTOs

Every endpoint needs Input and Output DTOs.

**Requirements:**
- Extend `Input` or `Output` base class
- All properties must be `final`
- Implement `fromJson` factory constructor
- Override `toJson()` method
- Override `toSchema()` method for OpenAPI docs

**📖 Detailed Guide:** [doc/usecase_dto_guide.md](doc/usecase_dto_guide.md)

**Example:**
```dart
class MyInput extends Input {
  final String name;
  
  MyInput({required this.name});
  
  factory MyInput.fromJson(Map<String, dynamic> json) {
    return MyInput(name: json['name'] as String);
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
```

### 2. Implement UseCase

**Requirements:**
- Extend `UseCase<InputType, OutputType>`
- Call `super(input)` in constructor
- Implement static `fromJson(Map<String, dynamic> json)` factory
- Override `execute()` method returning `Future<OutputType>`
- Keep business logic pure (no HTTP concerns)

**📖 Detailed Guide:** [doc/usecase_implementation.md](doc/usecase_implementation.md)

**Example:**
```dart
class MyUseCase extends UseCase<MyInput, MyOutput> {
  MyUseCase(super.input);
  
  static MyUseCase fromJson(Map<String, dynamic> json) {
    return MyUseCase(MyInput.fromJson(json));
  }
  
  @override
  Future<MyOutput> execute() async {
    // Business logic here
    return MyOutput(message: 'Hello, ${input.name}!');
  }
}
```

### 3. Create Module Builder

Encapsulate related use cases in a builder function:

```dart
void buildMyModule(ModuleBuilder m) {
  m.usecase('usecase-name', MyUseCase.fromJson);
  m.usecase('another-usecase', AnotherUseCase.fromJson);
}
```

### 4. Register Modules

```dart
final api = ModularApi(basePath: '/api');

api.module('module1', buildModule1);
api.module('users', buildUsersModule);

await api.serve(port: 8080);
```

**This creates endpoints like:**
- `POST /api/module1/usecase-name`
- `POST /api/users/create`

---

## Type Mapping for OpenAPI Schemas

When implementing `toSchema()`, use these mappings:

| Dart Type | OpenAPI Schema |
|-----------|----------------|
| `int` | `{'type': 'integer'}` |
| `double` | `{'type': 'number', 'format': 'double'}` |
| `String` | `{'type': 'string'}` |
| `bool` | `{'type': 'boolean'}` |
| `DateTime` | `{'type': 'string', 'format': 'date-time'}` |
| `List<T>` | `{'type': 'array', 'items': {...}}` |
| Custom class | `{'type': 'object', 'properties': {...}}` |

---

## Custom HTTP Status Codes (v0.0.8+)

Output DTOs can specify custom HTTP status codes by overriding the `statusCode` getter.

**Default Behavior:**
- All successful responses return HTTP 200 by default
- Override `statusCode` getter to return different codes

**Example: Error Response with Custom Status Code**
```dart
class ApiResponse extends Output {
  final int errorCode;
  final String message;
  final bool success;
  
  ApiResponse({
    required this.errorCode,
    required this.message,
    required this.success,
  });
  
  factory ApiResponse.fromJson(Map<String, dynamic> json) {
    return ApiResponse(
      errorCode: json['errorCode'] as int,
      message: json['message'] as String,
      success: json['success'] as bool,
    );
  }
  
  @override
  Map<String, dynamic> toJson() => {
    'errorCode': errorCode,
    'message': message,
    'success': success,
  };
  
  @override
  Map<String, dynamic> toSchema() => {
    'type': 'object',
    'properties': {
      'errorCode': {'type': 'integer'},
      'message': {'type': 'string'},
      'success': {'type': 'boolean'},
    },
    'required': ['errorCode', 'message', 'success'],
  };
  
  /// Map error codes to HTTP status codes
  @override
  int get statusCode {
    if (success) return 200;
    return switch (errorCode) {
      1001 => 400, // Bad Request
      1002 || 1003 => 401, // Unauthorized
      1004 => 403, // Forbidden
      1005 => 404, // Not Found
      1006 => 422, // Unprocessable Entity
      1007 => 503, // Service Unavailable
      _ => 500, // Internal Server Error
    };
  }
}
```

**Common HTTP Status Code Mappings:**
| Code | Meaning | Use Case |
|------|---------|----------|
| 200 | OK | Successful operation |
| 201 | Created | Resource created |
| 400 | Bad Request | Invalid input data |
| 401 | Unauthorized | Authentication required/failed |
| 403 | Forbidden | Insufficient permissions |
| 404 | Not Found | Resource not found |
| 422 | Unprocessable Entity | Validation errors |
| 500 | Internal Server Error | Unexpected errors |
| 503 | Service Unavailable | External service down |

---

## UseCaseException - Error Handling

The framework provides `UseCaseException` for throwing errors during use case execution with specific HTTP status codes.

**Features:**
- `statusCode` — HTTP status code to return (400, 404, 422, 500, etc.)
- `message` — Human-readable error message
- `errorCode` — Optional error code for client-side handling
- `details` — Optional additional details (validation errors, context)

**Example: Throwing Exceptions in execute()**
```dart
@override
Future<void> execute() async {
  // Validation errors
  if (input.userId.isEmpty) {
    throw UseCaseException(
      statusCode: 400,
      message: 'userId is required',
      errorCode: 'VALIDATION_ERROR',
    );
  }
  
  // Resource not found
  final user = await repository.findById(input.userId);
  if (user == null) {
    throw UseCaseException(
      statusCode: 404,
      message: 'User not found',
      errorCode: 'USER_NOT_FOUND',
    );
  }
  
  // Business logic errors
  if (!user.isActive) {
    throw UseCaseException(
      statusCode: 422,
      message: 'User account is inactive',
      errorCode: 'ACCOUNT_INACTIVE',
      details: {'userId': input.userId, 'status': user.status},
    );
  }
  
  // External service errors
  try {
    await externalService.process(user);
  } catch (e) {
    throw UseCaseException(
      statusCode: 503,
      message: 'External service unavailable',
      errorCode: 'SERVICE_UNAVAILABLE',
      details: {'service': 'payment-gateway'},
    );
  }
}
```

**JSON Response:**
```json
{
  "error": "USER_NOT_FOUND",
  "message": "User not found"
}
```

**With details:**
```json
{
  "error": "ACCOUNT_INACTIVE",
  "message": "User account is inactive",
  "details": {
    "userId": "12345",
    "status": "suspended"
  }
}
```

---

## OAuth2 Client Credentials (v0.0.9+)

### Built-in OAuth2 Authorization Server

The framework provides complete OAuth2 support with Client Credentials grant type for machine-to-machine authentication.

**Key Features:**
- `OAuthService` — JWT token generation and validation
- `OAuthClient` — Client registration with credentials and scopes
- `bearer()` middleware — Token validation and scope enforcement
- **Auto-mounting** — `/oauth/token` endpoint automatically registered
- HS256 (HMAC-SHA256) JWT signing
- Scope-based authorization per usecase

### Quick Setup

```dart
// 1. Create OAuth service
final oauthService = OAuthService(
  jwtSecret: Env.getString('JWT_SECRET'),
  issuer: 'your-domain.com',
  audience: 'your-domain.com',
  tokenTtlSeconds: 86400, // 24 hours
);

// 2. Register client
oauthService.registerClient(
  OAuthClient(
    clientId: 'client-id',
    clientSecret: 'secret',
    allowedScopes: ['read', 'write'],
    name: 'Client Name',
    isActive: true,
  ),
);

// 3. Create API with OAuth (auto-mounts /oauth/token)
final api = ModularApi(
  basePath: '/api',
  oauthService: oauthService,
);

// 4. Protect usecases with scopes
api.module('resources', (m) {
  m.usecase(
    'create',
    CreateResource.fromJson,
    requiredScopes: ['write'],
  );
});
```

### OAuth2 Flow

**1. Obtain Token:**
```bash
curl -X POST http://localhost:8080/oauth/token \
  -H "Content-Type: application/json" \
  -d '{
    "grant_type": "client_credentials",
    "client_id": "client-id",
    "client_secret": "secret",
    "scope": "read write"
  }'
```

**Response:**
```json
{
  "access_token": "eyJhbGc...",
  "token_type": "Bearer",
  "expires_in": 86400,
  "scope": "read write"
}
```

**2. Use Token:**
```bash
curl -X POST http://localhost:8080/api/resources/create \
  -H "Authorization: Bearer eyJhbGc..." \
  -H "Content-Type: application/json" \
  -d '{"name": "Resource 1"}'
```

### Features

- ✅ **Auto-mounting**: `/oauth/token` endpoint registered automatically when `oauthService` is provided
- ✅ **JWT Tokens**: HS256 signed with claims: iss, aud, sub, client_id, scopes, iat, exp
- ✅ **Scope Validation**: Per-usecase `requiredScopes` parameter
- ✅ **401/403 Responses**: Automatic unauthorized and forbidden responses
- ✅ **405 Support**: Proper HTTP method validation (POST required)

### Environment Variables

```env
JWT_SECRET=<generate-with-openssl-rand-base64-64>
JWT_ISSUER=your-domain.com
JWT_AUDIENCE=your-domain.com
OAUTH_CLIENT_ID=client-id
OAUTH_CLIENT_SECRET=<generate-with-openssl-rand-base64-32>
```

**Generate secure secrets:**
```bash
# JWT Secret (64 bytes)
openssl rand -base64 64

# Client Secret (32 bytes)
openssl rand -base64 32
```

---

## Authentication & HTTP Client (v0.0.7+)

### Single-User Design

The framework is optimized for **single-user applications** (one user at a time).

**Key Features:**
- `httpClient()` — Intelligent HTTP client with auto-authentication
- `Token` — In-memory session management
- `TokenVault` — Persistent storage for refresh tokens
- `JwtHelper` — JWT generation and validation
- `PasswordHasher` — bcrypt password hashing
- `TokenHasher` — SHA-256 token hashing

**📖 Complete Guide:** [doc/http_client_guide.md](doc/http_client_guide.md)

**📖 Auth Implementation:** [doc/auth_implementation_guide.md](doc/auth_implementation_guide.md)

### Quick httpClient Usage

```dart
// Login - auto-captures tokens
await httpClient(
  method: 'POST',
  baseUrl: 'https://api.example.com',
  endpoint: 'api/auth/login',
  body: {'username': 'user', 'password': 'pass'},
  auth: true,
);

// Protected request - auto-attaches Bearer token, auto-refreshes on 401
try {
  final data = await httpClient(
    method: 'GET',
    baseUrl: 'https://api.example.com',
    endpoint: 'api/users/profile',
    auth: true,
  );
} on AuthReLoginException {
  // Session expired - redirect to login
}

// Logout
Token.clear();
await TokenVault.deleteRefresh();
```

**Important:** No `user` parameter needed in v0.0.7+ (single-user optimized).

---

## Testing

Test UseCases directly by constructing them with fake/mock dependencies:

**📖 Complete Guide:** [doc/testing_guide.md](doc/testing_guide.md)

**Example:**
```dart
import 'package:test/test.dart';

void main() {
  test('MyUseCase should return expected output', () async {
    // ✅ Inject fake directly via constructor — no real infrastructure needed
    final useCase = MyUseCase(MyInput(name: 'World'), repository: FakeRepo());
    expect(useCase.validate(), isNull);
    await useCase.execute();
    expect(useCase.output.message, equals('Hello, World!'));
  });
}
```

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
- Provide test example using direct constructor injection with fakes

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
1. Show direct constructor injection pattern with fake dependencies
2. Provide complete test example with `package:test`
3. Show how to test validation errors with `useCase.validate()`
4. Explain testing without HTTP server (pure unit tests)

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

## Middlewares

```dart
final api = ModularApi(basePath: '/api')
  .use(cors())        // Enable CORS
  .use(apiKey());     // API Key authentication (reads from API_KEY env var)
```

---

## Environment Variables

Use `Env` utility for environment variables:

```dart
final apiKey = Env.getString('API_KEY');
final port = Env.getInt('PORT');
```

**Behavior (v0.0.4+):**
1. If `.env` file exists → read from it
2. If `.env` not found → fallback to `Platform.environment`
3. If key not found → throws `EnvKeyNotFoundException`

---

## Database Support

Built-in ODBC client for SQL Server and Oracle:

```dart
import 'package:modular_api/modular_api.dart';

final db = createSqlServerClient();
try {
  final rows = await db.execute('SELECT * FROM users');
  print(rows);
} finally {
  await db.disconnect();
}
```

---

## Project Structure Recommendation

```
lib/
  modules/
    module1/
      usecases/
        usecase_1.dart
        usecase_2.dart
      repositories/
        repository.dart
      module1_builder.dart      # Builder function
    module2/
      usecases/
        usecase_3.dart
      module2_builder.dart
  db/
    db_client.dart
bin/
  main.dart                     # Imports all builders
test/
  module1/
    usecase_1_test.dart
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
| Testing | Constructor injection | Supertest | MockMvc |

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

## Documentation Index

**📚 Complete Documentation:** [doc/INDEX.md](doc/INDEX.md)

**Essential Guides:**
- **[doc/usecase_dto_guide.md](doc/usecase_dto_guide.md)** — Creating Input/Output DTOs
- **[doc/usecase_implementation.md](doc/usecase_implementation.md)** — Implementing UseCases
- **[doc/testing_guide.md](doc/testing_guide.md)** — Testing UseCases with direct constructor injection
- **[doc/http_client_guide.md](doc/http_client_guide.md)** — Using httpClient (Flutter & Dart)
- **[doc/authentication_guide.md](doc/authentication_guide.md)** — Token management basics
- **[doc/auth_implementation_guide.md](doc/auth_implementation_guide.md)** — Complete JWT auth system

**Additional Resources:**
- `example/` folder — Minimal runnable example

---

## Installation

```yaml
# pubspec.yaml
dependencies:
  modular_api: ^0.0.7
```

Or:
```bash
dart pub add modular_api
```

---

## Quick Commands

```bash
# Run server
dart run bin/main.dart

# Run tests
dart test

# Compile to executable
dart compile exe bin/main.dart -o build/server
```

---

## AI Agent Best Practices

When assisting users:

1. ✅ **Always generate complete code** — Include all three DTO methods, full UseCase, and registration
2. ✅ **Reference the detailed guides** — Point to specific documentation files
3. ✅ **Follow the pattern** — Input → UseCase → Output (no HTTP in business logic)
4. ✅ **Include tests** — Show direct constructor injection examples with fakes
5. ✅ **Suggest file organization** — Especially for multi-module projects
6. ✅ **Explain automatic features** — Health endpoint, docs, error handling
7. ✅ **Validate schemas** — Ensure toSchema() matches class properties
8. ✅ **Use dependency injection** — Never create deps inside execute()
9. ✅ **Provide curl examples** — Help users test immediately
10. ✅ **Keep it simple** — Start minimal, add complexity only when needed

---

**This framework prioritizes clean architecture, testability, and separation of concerns.**
