# modular_api Documentation Index

Use-case centric API toolkit for Dart — Shelf + OpenAPI, nothing more.

---

## Development Flow

Implement features following this **bottom-up** vertical flow with TDD at each stage:

```
Repository → UseCase → API Routes → Tests
```

Each stage must be tested before moving to the next.

---

## Stage 1: Repository and Data Access

**Objective**: Implement data interaction layer.

**Steps**:
1. Write repository unit tests
2. Implement repository methods
3. Test queries and data mapping
4. Validate error handling

**Validation**:
- ✅ Queries execute without errors
- ✅ Results map correctly to domain entities
- ✅ Error handling for failures

---

## Stage 2: UseCase Implementation

**Objective**: Implement business logic in `execute()` method.

**Primary Guide**: [usecase_implementation.md](./usecase_implementation.md)  
**Required First**: [usecase_dto_guide.md](./usecase_dto_guide.md)

**Steps**:
1. Create Input/Output DTOs following the DTO guide
2. Implement UseCase class extending `UseCase<Input, Output>`
3. Write unit tests using direct constructor injection
4. Implement `execute()` method with business logic
5. Test and refactor until all tests pass

**Key Points**:
- UseCases receive Input DTOs and return Output DTOs
- Business logic stays pure (no HTTP concerns)
- Dependencies injected via constructor
- Validation in `validate()` method (optional) or at start of `execute()`

**Testing Guide**: [testing_guide.md](./testing_guide.md)

**Validation**:
- ✅ Business logic executes correctly
- ✅ Edge cases handled properly

---

## Stage 3: API Integration

**Objective**: Expose UseCases via HTTP endpoints and validate end-to-end.

**Guide**: [AGENTS.md](../AGENTS.md)

**Steps**:
1. Register modules and usecases in `ModularApi`
2. Configure middlewares (CORS)
3. Test HTTP flows
4. Validate routes and serialization

**Example Registration**:
```dart
final api = ModularApi(basePath: '/api');

api.module('users', (m) {
  m.usecase('create', CreateUser.fromJson);
  m.usecase('get', GetUser.fromJson, method: 'GET');
});

api.use(cors());
await api.serve(port: 8080);
```

**Validation**:
- ✅ HTTP routes respond with correct status codes
- ✅ DTOs serialize/deserialize properly
- ✅ Middlewares function as expected

---

## Quick Reference: Guides by Topic

### Core Framework
- **[AGENTS.md](../AGENTS.md)** — Framework overview, ModularApi usage, module registration
- **[usecase_dto_guide.md](./usecase_dto_guide.md)** — Creating Input/Output DTOs
- **[usecase_implementation.md](./usecase_implementation.md)** — Implementing UseCases
- **[testing_guide.md](./testing_guide.md)** — Testing UseCases with direct constructor injection
- **[health_check_guide.md](./health_check_guide.md)** — Health check endpoint (`GET /health`)
- **[metrics_guide.md](./metrics_guide.md)** — Prometheus metrics endpoint (`GET /metrics`)
- **[logger_guide.md](./logger_guide.md)** — Structured JSON logging (Loki/Grafana compatible)

---

## Common Patterns

### UseCase Factory Pattern
```dart
class MyUseCase extends UseCase<MyInput, MyOutput> {
  MyUseCase(super.input);
  
  static MyUseCase fromJson(Map<String, dynamic> json) {
    return MyUseCase(MyInput.fromJson(json));
  }
  
  @override
  Future<MyOutput> execute() async {
    // Business logic
    return MyOutput(result: data);
  }
}
```

### Module Builder Pattern
```dart
void buildMyModule(ModuleBuilder m) {
  m.usecase('action1', UseCase1.fromJson);
  m.usecase('action2', UseCase2.fromJson);
}

// In main.dart
api.module('mymodule', buildMyModule);
```

---

## Key Principles

1. **Test-Driven Development (TDD)** — Write tests before implementation
2. **Vertical Slicing** — Implement complete features
3. **Clean Separation** — Clear boundaries between layers
4. **UseCase Purity** — Business logic independent of HTTP concerns
5. **Dependency Injection** — Inject dependencies, don't create them internally

---

**Start here, follow the flow, test at every stage.**
