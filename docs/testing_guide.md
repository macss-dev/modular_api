# UseCase Testing Guide

Quick guide for writing unit tests for UseCases using `useCaseTestHandler`.

---

## Basic Setup

```dart
import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';

void main() {
  group('MyUseCase', () {
    test('test description', () async {
      // Test code here
    });
  });
}
```

---

## Using useCaseTestHandler

The `useCaseTestHandler` creates a test function that:
1. Builds the UseCase from JSON input
2. Validates the input data
3. Executes the use case
4. Returns `true` if successful, `false` if validation fails or an exception occurs

### Basic Pattern

```dart
test('should execute successfully with valid input', () async {
  // 1. Prepare input data
  final input = {'field1': 'value1', 'field2': 42};
  
  // 2. Create test handler
  final handler = useCaseTestHandler(MyUseCase.fromJson);
  
  // 3. Execute and assert
  final result = await handler(input);
  expect(result, isTrue);
});
```

---

## Complete Example

Assuming you have this UseCase:

```dart
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
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'a': {'type': 'integer'},
        'b': {'type': 'integer'},
      },
      'required': ['a', 'b'],
    };
  }
}

class SumOutput extends Output {
  final int result;
  
  SumOutput({required this.result});
  
  factory SumOutput.fromJson(Map<String, dynamic> json) {
    return SumOutput(result: json['result'] as int);
  }
  
  @override
  Map<String, dynamic> toJson() => {'result': result};
  
  @override
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'result': {'type': 'integer'},
      },
      'required': ['result'],
    };
  }
}

class SumNumbers extends UseCase<SumInput, SumOutput> {
  SumNumbers(super.input);
  
  static SumNumbers fromJson(Map<String, dynamic> json) {
    return SumNumbers(SumInput.fromJson(json));
  }
  
  @override
  Future<SumOutput> execute() async {
    final result = input.a + input.b;
    return SumOutput(result: result);
  }
}
```

### Test File

```dart
import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';
import '../lib/usecases/sum_numbers.dart';

void main() {
  group('SumNumbers UseCase', () {
    test('should sum two positive numbers', () async {
      final input = {'a': 5, 'b': 3};
      final handler = useCaseTestHandler(SumNumbers.fromJson);
      
      final result = await handler(input);
      
      expect(result, isTrue);
    });

    test('should handle negative numbers', () async {
      final input = {'a': -10, 'b': 5};
      final handler = useCaseTestHandler(SumNumbers.fromJson);
      
      final result = await handler(input);
      
      expect(result, isTrue);
    });

    test('should handle zero', () async {
      final input = {'a': 0, 'b': 0};
      final handler = useCaseTestHandler(SumNumbers.fromJson);
      
      final result = await handler(input);
      
      expect(result, isTrue);
    });
  });
}
```

---

## Testing Validation Failures

When input validation fails, `useCaseTestHandler` returns `false`:

```dart
test('should return false when validation fails', () async {
  // Assuming your UseCase validates that 'age' must be >= 18
  final input = {'name': 'John', 'age': 15};
  final handler = useCaseTestHandler(CreateUser.fromJson);
  
  final result = await handler(input);
  
  expect(result, isFalse);
});
```

---

## Testing Exceptions

When an exception is thrown during execution, `useCaseTestHandler` returns `false`:

```dart
test('should return false when exception occurs', () async {
  // Assuming the UseCase throws an exception for invalid data
  final input = {'userId': 'non-existent-id'};
  final handler = useCaseTestHandler(GetUser.fromJson);
  
  final result = await handler(input);
  
  expect(result, isFalse);
});
```

---

## Multiple Test Cases

```dart
void main() {
  group('CalculateDiscount UseCase', () {
    final handler = useCaseTestHandler(CalculateDiscount.fromJson);

    test('should apply 10% discount for regular customers', () async {
      final result = await handler({
        'amount': 100.0,
        'customerType': 'regular',
      });
      expect(result, isTrue);
    });

    test('should apply 20% discount for premium customers', () async {
      final result = await handler({
        'amount': 100.0,
        'customerType': 'premium',
      });
      expect(result, isTrue);
    });

    test('should reject negative amounts', () async {
      final result = await handler({
        'amount': -50.0,
        'customerType': 'regular',
      });
      expect(result, isFalse);
    });
  });
}
```

---

## Testing with Dependencies

If your UseCase has dependencies (DB, repositories), create them in the test:

```dart
test('should retrieve user from database', () async {
  // Mock or create real dependencies
  final mockDb = MockDbClient();
  
  // Create a custom test that injects dependencies
  final input = {'userId': '123'};
  final useCase = GetUser(
    GetUserInput.fromJson(input),
    db: mockDb,
  );
  
  final output = await useCase.execute();
  
  expect(output.userId, equals('123'));
});
```

**Note:** For complex dependency testing, you may want to test the UseCase directly instead of using `useCaseTestHandler`.

---

## Quick Reference

| Test Scenario | Expected Result |
|---------------|-----------------|
| Valid input, successful execution | `result == true` |
| Invalid input (validation fails) | `result == false` |
| Exception thrown during execution | `result == false` |
| Business logic error | `result == false` |

---

## Best Practices

1. **One assertion per test** — Test one scenario at a time
2. **Descriptive test names** — Use `should [expected behavior] when [condition]`
3. **Group related tests** — Use `group()` to organize tests by UseCase
4. **Test edge cases** — Include boundary values, null cases, empty strings, etc.
5. **Test both success and failure paths** — Don't just test happy paths

---

## Running Tests

```powershell
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
  group('MyUseCase', () {
    test('should succeed with valid input', () async {
      final input = {'field': 'value'};
      final handler = useCaseTestHandler(MyUseCase.fromJson);
      final result = await handler(input);
      expect(result, isTrue);
    });
    
    test('should fail with invalid input', () async {
      final input = {'field': 'invalid'};
      final handler = useCaseTestHandler(MyUseCase.fromJson);
      final result = await handler(input);
      expect(result, isFalse);
    });
  });
}
```

That's it! Simple, focused unit tests for your UseCases.
