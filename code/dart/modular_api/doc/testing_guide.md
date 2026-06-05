# UseCase Testing Guide

Guide for writing unit tests for UseCases using direct constructor injection.

---

## Core Pattern

Test UseCases by constructing them directly with their dependencies. This allows injecting fakes/mocks instead of real infrastructure, keeping tests fast and isolated.

```dart
import 'package:test/test.dart';

void main() {
  group('MyUseCase', () {
    test('test description', () async {
      final useCase = MyUseCase(MyInput(field: 'value'));
      expect(useCase.validate(), isNull);
      final output = await useCase.execute();
      expect(output.result, equals('expected'));
    });
  });
}
```

---

## Complete Example

Assuming you have this UseCase with a repository dependency:

```dart
abstract class SumRepository {
  Future<void> saveResult(int result);
}

class SumInput extends Input {
  final int a;

  final int b;
  
  SumInput({required this.a, required this.b});
  
  factory SumInput.fromJson(Map<String, dynamic> json) {
    return SumInput(a: json['a'] as int, b: json['b'] as int);
  }
  
  @override
  Map<String, dynamic> toJson() => {'a': a, 'b': b};

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.integer('a', description: 'First operand'),
        SchemaField.integer('b', description: 'Second operand'),
      ];
}
}

class SumOutput extends Output {
  final int result;
  
  SumOutput({required this.result});
  
  factory SumOutput.fromJson(Map<String, dynamic> json) {
    return SumOutput(result: json['result'] as int);
  }
  
  @override
  int get statusCode => 200;
  
  @override
  Map<String, dynamic> toJson() => {'result': result};

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.integer('result', description: 'Sum result'),
      ];
}

class SumNumbers implements UseCase<SumInput, SumOutput> {
  @override
  final SumInput input;
  @override
  late SumOutput output;
  @override
  ModularLogger? logger;

  final SumRepository repository;

  SumNumbers(this.input, {required this.repository});

  static SumNumbers fromJson(Map<String, dynamic> json) {
    return SumNumbers(SumInput.fromJson(json), repository: RealSumRepository());
  }

  @override
  String? validate() {
    if (input.a < 0 || input.b < 0) return 'values must be non-negative';
    return null;
  }

  @override
  Future<SumOutput> execute() async {
    final result = input.a + input.b;
    await repository.saveResult(result);
    return SumOutput(result: result);
  }
}
```

### Fake Repository

```dart
class FakeSumRepository implements SumRepository {
  final List<int> savedResults = [];

  @override
  Future<void> saveResult(int result) async {
    savedResults.add(result);
  }
}
```

### Test File

```dart
import 'package:test/test.dart';
import '../lib/usecases/sum_numbers.dart';

void main() {
  late FakeSumRepository fakeRepo;

  setUp(() {
    fakeRepo = FakeSumRepository();
  });

  group('SumNumbers UseCase', () {
    test('should sum two positive numbers', () async {
      // ✅ Inject fake directly via constructor
      final useCase = SumNumbers(
        SumInput(a: 5, b: 3),
        repository: fakeRepo,
      );

      expect(useCase.validate(), isNull);
      await useCase.execute();

      expect(useCase.output.result, equals(8));
      expect(fakeRepo.savedResults, equals([8]));
    });

    test('should handle zero values', () async {
      final useCase = SumNumbers(
        SumInput(a: 0, b: 0),
        repository: fakeRepo,
      );

      await useCase.execute();

      expect(useCase.output.result, equals(0));
    });

    test('should reject negative values', () {
      final useCase = SumNumbers(
        SumInput(a: -1, b: 3),
        repository: fakeRepo,
      );

      expect(useCase.validate(), isNotNull);
      expect(useCase.validate(), contains('non-negative'));
    });
  });
}
```

---

## Testing Validation

Call `validate()` directly and assert on the returned string:

```dart
test('should return error message when age is under 18', () {
  final useCase = CreateUser(
    CreateUserInput(name: 'John', age: 15),
    repository: fakeRepo,
  );

  expect(useCase.validate(), isNotNull);
  expect(useCase.validate(), contains('18'));
});

test('should return null when input is valid', () {
  final useCase = CreateUser(
    CreateUserInput(name: 'John', age: 20),
    repository: fakeRepo,
  );

  expect(useCase.validate(), isNull);
});
```

---

## Testing Exceptions

Use `throwsA` to assert on exceptions thrown during `execute()`:

```dart
class FakeFailingRepository implements SumRepository {
  @override
  Future<void> saveResult(int result) async {
    throw UseCaseException(
      statusCode: 503,
      message: 'Database unavailable',
      errorCode: 'DB_ERROR',
    );
  }
}

test('should throw UseCaseException when repository fails', () {
  final useCase = SumNumbers(
    SumInput(a: 5, b: 3),
    repository: FakeFailingRepository(),
  );

  expect(
    () => useCase.execute(),
    throwsA(isA<UseCaseException>()),
  );
});
```

---

## Testing Two Approaches

| Approach | When to use | How |
|----------|-------------|-----|
| **Unit test (constructor)** | Always — default for business logic | `SumNumbers(input, repository: fakeRepo)` |
| **Integration test (fromJson)** | When testing with real infrastructure | `SumNumbers.fromJson(json)` directly |

Unit tests run fast and require no external infrastructure. Integration tests are reserved for validating end-to-end behavior with real databases and services.

---

## Best Practices

1. **Inject fakes via constructor** — Never use `fromJson` in unit tests; it wires real adapters
2. **One assertion per test** — Test one scenario at a time
3. **Descriptive test names** — Use `should [expected behavior] when [condition]`
4. **Group related tests** — Use `group()` to organize tests by UseCase
5. **Test edge cases** — Include boundary values, null cases, empty strings, etc.
6. **Assert on output AND side effects** — Check `useCase.output` and fake state (e.g. `fakeRepo.savedResults`)
7. **Test both success and failure paths** — Don't just test happy paths

---

## Running Tests

```bash
# Run all tests
dart test

# Run specific test file
dart test test/usecases/sum_numbers_test.dart

# Run with coverage
dart test --coverage=coverage
dart pub global activate coverage
dart pub global run coverage:format_coverage --lcov --in=coverage --out=coverage/lcov.info --report-on=lib
```

---

## Summary

**Typical test structure:**

```dart
import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';

void main() {
  late FakeRepository fakeRepo;

  setUp(() => fakeRepo = FakeRepository());

  group('MyUseCase', () {
    test('should succeed with valid input', () async {
      final useCase = MyUseCase(MyInput(field: 'value'), repository: fakeRepo);
      expect(useCase.validate(), isNull);
      await useCase.execute();
      expect(useCase.output.result, equals('expected'));
    });

    test('should fail validation with invalid input', () {
      final useCase = MyUseCase(MyInput(field: ''), repository: fakeRepo);
      expect(useCase.validate(), isNotNull);
    });
  });
}
```

That's it! Direct constructor injection gives you full control over dependencies in tests.
