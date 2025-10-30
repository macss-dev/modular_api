# UseCase Implementation Guide

This guide provides clear and precise instructions for implementing use cases in the `modular_api` framework, assuming you already have your Input and Output DTOs properly generated.

> **Prerequisites:** Before following this guide, ensure you have created your Input and Output DTOs following the [USECASE_DTO_GUIDE.md](./USECASE_DTO_GUIDE.md).

---

## 📋 Overview

A **UseCase** is a class that encapsulates a single business operation. It follows this flow:

1. **Receive Input** — Accept validated input data
2. **Execute Logic** — Perform the business operation
3. **Return Output** — Return the result

Every UseCase must:
- Extend `UseCase<InputType, OutputType>`
- Implement the `execute()` method
- Include a static `fromJson` factory for HTTP integration

---

## 🎯 Step-by-Step Guide

### Step 1: Basic UseCase Structure

```dart
import 'package:modular_api/modular_api.dart';

class MyUseCase extends UseCase<MyUseCaseInput, MyUseCaseOutput> {
  MyUseCase(super.input);

  // Factory constructor for HTTP integration
  static MyUseCase fromJson(Map<String, dynamic> json) {
    return MyUseCase(MyUseCaseInput.fromJson(json));
  }

  @override
  Future<MyUseCaseOutput> execute() async {
    // Your business logic here
    
    return MyUseCaseOutput(/* result data */);
  }
}
```

### Step 2: Implementing the execute() Method

The `execute()` method contains your business logic. Here's the pattern:

```dart
@override
Future<MyUseCaseOutput> execute() async {
  // 1. Extract input data
  final value1 = input.value1;
  final value2 = input.value2;
  
  // 2. Perform business logic
  final result = value1 + value2;
  
  // 3. Return output
  return MyUseCaseOutput(result: result);
}
```

---

## 💡 Complete Example: Simple Calculation

Let's implement a use case that takes two numbers and returns their sum.

**Assuming you have these DTOs:**

```dart
class SumInput extends Input {
  final int a;
  final int b;
  
  SumInput({required this.a, required this.b});
  
  factory SumInput.fromJson(Map<String, dynamic> json) {
    return SumInput(
      a: json['a'] as int,
      b: json['b'] as int,
    );
  }
  
  @override
  Map<String, dynamic> toJson() => {'a': a, 'b': b};
  
  @override
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'a': {'type': 'integer', 'description': 'First number'},
        'b': {'type': 'integer', 'description': 'Second number'},
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
        'result': {'type': 'integer', 'description': 'Sum result'},
      },
      'required': ['result'],
    };
  }
}
```

**Now implement the UseCase:**

```dart
import 'package:modular_api/modular_api.dart';

class SumNumbers extends UseCase<SumInput, SumOutput> {
  SumNumbers(super.input);

  static SumNumbers fromJson(Map<String, dynamic> json) {
    return SumNumbers(SumInput.fromJson(json));
  }

  @override
  Future<SumOutput> execute() async {
    // Extract input values
    final a = input.a;
    final b = input.b;
    
    // Perform calculation
    final result = a + b;
    
    // Return output
    return SumOutput(result: result);
  }
}
```

---

## 🔧 Advanced Examples

### Example 1: UseCase with Validation

```dart
class CreateUserInput extends Input {
  final String name;
  final String email;
  final int age;
  
  CreateUserInput({required this.name, required this.email, required this.age});
  
  factory CreateUserInput.fromJson(Map<String, dynamic> json) {
    return CreateUserInput(
      name: json['name'] as String,
      email: json['email'] as String,
      age: json['age'] as int,
    );
  }
  
  @override
  Map<String, dynamic> toJson() => {'name': name, 'email': email, 'age': age};
  
  @override
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'name': {'type': 'string', 'description': 'User name'},
        'email': {'type': 'string', 'format': 'email', 'description': 'User email'},
        'age': {'type': 'integer', 'description': 'User age'},
      },
      'required': ['name', 'email', 'age'],
    };
  }
}

class CreateUserOutput extends Output {
  final String userId;
  final String message;
  
  CreateUserOutput({required this.userId, required this.message});
  
  factory CreateUserOutput.fromJson(Map<String, dynamic> json) {
    return CreateUserOutput(
      userId: json['userId'] as String,
      message: json['message'] as String,
    );
  }
  
  @override
  Map<String, dynamic> toJson() => {'userId': userId, 'message': message};
  
  @override
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'userId': {'type': 'string', 'description': 'Generated user ID'},
        'message': {'type': 'string', 'description': 'Success message'},
      },
      'required': ['userId', 'message'],
    };
  }
}

class CreateUser extends UseCase<CreateUserInput, CreateUserOutput> {
  CreateUser(super.input);

  static CreateUser fromJson(Map<String, dynamic> json) {
    return CreateUser(CreateUserInput.fromJson(json));
  }

  @override
  Future<CreateUserOutput> execute() async {
    // Validate input
    if (input.name.isEmpty) {
      throw ArgumentError('Name cannot be empty');
    }
    
    if (!input.email.contains('@')) {
      throw ArgumentError('Invalid email format');
    }
    
    if (input.age < 18) {
      throw ArgumentError('User must be 18 or older');
    }
    
    // Business logic: create user (simulate with ID generation)
    final userId = 'USER_${DateTime.now().millisecondsSinceEpoch}';
    
    // Return success
    return CreateUserOutput(
      userId: userId,
      message: 'User ${input.name} created successfully',
    );
  }
}
```

### Example 2: UseCase with Database Access

```dart
class GetUserInput extends Input {
  final String userId;
  
  GetUserInput({required this.userId});
  
  factory GetUserInput.fromJson(Map<String, dynamic> json) {
    return GetUserInput(userId: json['userId'] as String);
  }
  
  @override
  Map<String, dynamic> toJson() => {'userId': userId};
  
  @override
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'userId': {'type': 'string', 'description': 'User ID to retrieve'},
      },
      'required': ['userId'],
    };
  }
}

class GetUserOutput extends Output {
  final String userId;
  final String name;
  final String email;
  
  GetUserOutput({required this.userId, required this.name, required this.email});
  
  factory GetUserOutput.fromJson(Map<String, dynamic> json) {
    return GetUserOutput(
      userId: json['userId'] as String,
      name: json['name'] as String,
      email: json['email'] as String,
    );
  }
  
  @override
  Map<String, dynamic> toJson() => {'userId': userId, 'name': name, 'email': email};
  
  @override
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'userId': {'type': 'string', 'description': 'User ID'},
        'name': {'type': 'string', 'description': 'User name'},
        'email': {'type': 'string', 'description': 'User email'},
      },
      'required': ['userId', 'name', 'email'],
    };
  }
}

class GetUser extends UseCase<GetUserInput, GetUserOutput> {
  final DbClient _db;
  
  GetUser(super.input, {required DbClient db}) : _db = db;

  static GetUser fromJson(Map<String, dynamic> json) {
    // In a real application, inject the database client
    final db = createDatabaseClient(); // Your DB factory
    return GetUser(GetUserInput.fromJson(json), db: db);
  }

  @override
  Future<GetUserOutput> execute() async {
    // Query database
    final rows = await _db.execute(
      'SELECT user_id, name, email FROM users WHERE user_id = ?',
      [input.userId],
    );
    
    // Check if user exists
    if (rows.isEmpty) {
      throw Exception('User not found: ${input.userId}');
    }
    
    // Parse result
    final row = rows.first;
    
    // Return output
    return GetUserOutput(
      userId: row['user_id'] as String,
      name: row['name'] as String,
      email: row['email'] as String,
    );
  }
}
```

### Example 3: UseCase with Repository Pattern

```dart
// Repository interface
abstract class UserRepository {
  Future<User?> findById(String id);
  Future<User> save(User user);
}

// Domain model
class User {
  final String id;
  final String name;
  final String email;
  
  User({required this.id, required this.name, required this.email});
}

// DTOs (Input/Output)
class UpdateUserInput extends Input {
  final String userId;
  final String newName;
  final String newEmail;
  
  UpdateUserInput({
    required this.userId,
    required this.newName,
    required this.newEmail,
  });
  
  factory UpdateUserInput.fromJson(Map<String, dynamic> json) {
    return UpdateUserInput(
      userId: json['userId'] as String,
      newName: json['newName'] as String,
      newEmail: json['newEmail'] as String,
    );
  }
  
  @override
  Map<String, dynamic> toJson() => {
    'userId': userId,
    'newName': newName,
    'newEmail': newEmail,
  };
  
  @override
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'userId': {'type': 'string', 'description': 'User ID'},
        'newName': {'type': 'string', 'description': 'New user name'},
        'newEmail': {'type': 'string', 'format': 'email', 'description': 'New email'},
      },
      'required': ['userId', 'newName', 'newEmail'],
    };
  }
}

class UpdateUserOutput extends Output {
  final bool success;
  final String message;
  
  UpdateUserOutput({required this.success, required this.message});
  
  factory UpdateUserOutput.fromJson(Map<String, dynamic> json) {
    return UpdateUserOutput(
      success: json['success'] as bool,
      message: json['message'] as String,
    );
  }
  
  @override
  Map<String, dynamic> toJson() => {'success': success, 'message': message};
  
  @override
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'success': {'type': 'boolean', 'description': 'Operation success status'},
        'message': {'type': 'string', 'description': 'Result message'},
      },
      'required': ['success', 'message'],
    };
  }
}

// UseCase implementation
class UpdateUser extends UseCase<UpdateUserInput, UpdateUserOutput> {
  final UserRepository _repository;
  
  UpdateUser(super.input, {required UserRepository repository})
      : _repository = repository;

  static UpdateUser fromJson(Map<String, dynamic> json) {
    // Inject repository (use your DI container or factory)
    final repository = createUserRepository();
    return UpdateUser(UpdateUserInput.fromJson(json), repository: repository);
  }

  @override
  Future<UpdateUserOutput> execute() async {
    // 1. Find user
    final user = await _repository.findById(input.userId);
    
    if (user == null) {
      return UpdateUserOutput(
        success: false,
        message: 'User not found: ${input.userId}',
      );
    }
    
    // 2. Update user
    final updatedUser = User(
      id: user.id,
      name: input.newName,
      email: input.newEmail,
    );
    
    // 3. Save changes
    await _repository.save(updatedUser);
    
    // 4. Return success
    return UpdateUserOutput(
      success: true,
      message: 'User updated successfully',
    );
  }
}
```

### Example 4: UseCase with External API Call

```dart
class WeatherInput extends Input {
  final String city;
  
  WeatherInput({required this.city});
  
  factory WeatherInput.fromJson(Map<String, dynamic> json) {
    return WeatherInput(city: json['city'] as String);
  }
  
  @override
  Map<String, dynamic> toJson() => {'city': city};
  
  @override
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'city': {'type': 'string', 'description': 'City name'},
      },
      'required': ['city'],
    };
  }
}

class WeatherOutput extends Output {
  final String city;
  final double temperature;
  final String condition;
  
  WeatherOutput({
    required this.city,
    required this.temperature,
    required this.condition,
  });
  
  factory WeatherOutput.fromJson(Map<String, dynamic> json) {
    return WeatherOutput(
      city: json['city'] as String,
      temperature: (json['temperature'] as num).toDouble(),
      condition: json['condition'] as String,
    );
  }
  
  @override
  Map<String, dynamic> toJson() => {
    'city': city,
    'temperature': temperature,
    'condition': condition,
  };
  
  @override
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'city': {'type': 'string', 'description': 'City name'},
        'temperature': {'type': 'number', 'description': 'Temperature in Celsius'},
        'condition': {'type': 'string', 'description': 'Weather condition'},
      },
      'required': ['city', 'temperature', 'condition'],
    };
  }
}

class GetWeather extends UseCase<WeatherInput, WeatherOutput> {
  final http.Client _httpClient;
  
  GetWeather(super.input, {http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  static GetWeather fromJson(Map<String, dynamic> json) {
    return GetWeather(WeatherInput.fromJson(json));
  }

  @override
  Future<WeatherOutput> execute() async {
    // Call external weather API
    final apiKey = Env.getString('WEATHER_API_KEY');
    final url = 'https://api.weatherapi.com/v1/current.json?key=$apiKey&q=${input.city}';
    
    final response = await _httpClient.get(Uri.parse(url));
    
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch weather data: ${response.statusCode}');
    }
    
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    
    // Parse response
    return WeatherOutput(
      city: data['location']['name'] as String,
      temperature: (data['current']['temp_c'] as num).toDouble(),
      condition: data['current']['condition']['text'] as String,
    );
  }
}
```

---

## 🔗 Registering UseCases in ModularApi

Once your UseCase is implemented, register it in your API:

```dart
import 'package:modular_api/modular_api.dart';

Future<void> main() async {
  final api = ModularApi(basePath: '/api');

  // Register modules and usecases
  api.module('calculations', (m) {
    m.usecase('sum', SumNumbers.fromJson);
  });

  api.module('users', (m) {
    m.usecase('create', CreateUser.fromJson);
    m.usecase('get', GetUser.fromJson);
    m.usecase('update', UpdateUser.fromJson);
  });

  api.module('weather', (m) {
    m.usecase('current', GetWeather.fromJson);
  });

  await api.serve(port: 8080);
  print('API running on http://localhost:8080');
  print('Docs available at http://localhost:8080/docs');
}
```

This creates the following endpoints:
- `POST /api/calculations/sum`
- `POST /api/users/create`
- `POST /api/users/get`
- `POST /api/users/update`
- `POST /api/weather/current`

---

## 🧪 Testing UseCases

Use the `useCaseTestHandler` helper for unit testing:

```dart
import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';

void main() {
  group('SumNumbers UseCase', () {
    test('should sum two numbers correctly', () async {
      // Arrange
      final input = {'a': 5, 'b': 3};
      final handler = useCaseTestHandler(SumNumbers.fromJson);

      // Act
      final response = await handler(input);

      // Assert
      expect(response.statusCode, equals(200));
      final body = jsonDecode(await response.readAsString());
      expect(body['result'], equals(8));
    });

    test('should handle large numbers', () async {
      final input = {'a': 1000000, 'b': 2000000};
      final handler = useCaseTestHandler(SumNumbers.fromJson);

      final response = await handler(input);

      expect(response.statusCode, equals(200));
      final body = jsonDecode(await response.readAsString());
      expect(body['result'], equals(3000000));
    });
  });

  group('CreateUser UseCase', () {
    test('should create user with valid input', () async {
      final input = {
        'name': 'John Doe',
        'email': 'john@example.com',
        'age': 25,
      };
      final handler = useCaseTestHandler(CreateUser.fromJson);

      final response = await handler(input);

      expect(response.statusCode, equals(200));
      final body = jsonDecode(await response.readAsString());
      expect(body['userId'], startsWith('USER_'));
      expect(body['message'], contains('created successfully'));
    });

    test('should reject invalid email', () async {
      final input = {
        'name': 'John Doe',
        'email': 'invalid-email',
        'age': 25,
      };
      final handler = useCaseTestHandler(CreateUser.fromJson);

      final response = await handler(input);

      expect(response.statusCode, equals(500));
    });

    test('should reject underage user', () async {
      final input = {
        'name': 'John Doe',
        'email': 'john@example.com',
        'age': 16,
      };
      final handler = useCaseTestHandler(CreateUser.fromJson);

      final response = await handler(input);

      expect(response.statusCode, equals(500));
    });
  });
}
```

---

## ✅ Checklist

When implementing a UseCase, ensure:

- [ ] Class extends `UseCase<InputType, OutputType>` with correct generic types
- [ ] Constructor calls `super(input)` or accepts input parameter
- [ ] Static `fromJson` factory method is implemented
- [ ] `fromJson` creates the Input DTO using `InputType.fromJson(json)`
- [ ] `execute()` method is implemented and marked as `@override`
- [ ] `execute()` returns `Future<OutputType>`
- [ ] All input values are accessed via `input.propertyName`
- [ ] Business logic is clearly organized and readable
- [ ] Validation errors throw appropriate exceptions
- [ ] Output DTO is properly constructed with all required fields
- [ ] Dependencies (DB, repositories, HTTP clients) are injected via constructor
- [ ] UseCase is registered in `ModularApi` with correct module and path
- [ ] Unit tests are written using `useCaseTestHandler`

---

## 🚀 Quick Template

Copy and adapt this template for new UseCases:

```dart
import 'package:modular_api/modular_api.dart';

class MyUseCase extends UseCase<MyUseCaseInput, MyUseCaseOutput> {
  // Add dependencies here (repository, DB client, HTTP client, etc.)
  // final MyRepository _repository;
  
  MyUseCase(super.input /* , {required MyRepository repository} */) 
      // : _repository = repository
      ;

  static MyUseCase fromJson(Map<String, dynamic> json) {
    // Inject dependencies here
    // final repository = createMyRepository();
    return MyUseCase(
      MyUseCaseInput.fromJson(json),
      // repository: repository,
    );
  }

  @override
  Future<MyUseCaseOutput> execute() async {
    // 1. Extract input
    final value = input.value;
    
    // 2. Validate if needed
    if (value.isEmpty) {
      throw ArgumentError('Value cannot be empty');
    }
    
    // 3. Perform business logic
    final result = await _performOperation(value);
    
    // 4. Return output
    return MyUseCaseOutput(result: result);
  }
  
  // Private helper methods
  Future<String> _performOperation(String value) async {
    // Your logic here
    return value.toUpperCase();
  }
}
```

---

## 📖 Best Practices

### 1. Single Responsibility
Each UseCase should do **one thing** and do it well. If your `execute()` method is getting too complex, consider breaking it into smaller UseCases.

### 2. Dependency Injection
Always inject dependencies (repositories, DB clients, HTTP clients) through the constructor rather than creating them inside the UseCase.

```dart
// ✅ Good
class MyUseCase extends UseCase<MyInput, MyOutput> {
  final MyRepository _repository;
  
  MyUseCase(super.input, {required MyRepository repository})
      : _repository = repository;
}

// ❌ Bad
class MyUseCase extends UseCase<MyInput, MyOutput> {
  MyUseCase(super.input);
  
  @override
  Future<MyOutput> execute() async {
    final repository = MyRepository(); // Don't create dependencies here
    // ...
  }
}
```

### 3. Error Handling
Use meaningful exceptions and let the framework handle HTTP error responses:

```dart
@override
Future<MyOutput> execute() async {
  if (input.value < 0) {
    throw ArgumentError('Value must be positive');
  }
  
  final result = await _repository.find(input.id);
  
  if (result == null) {
    throw Exception('Resource not found: ${input.id}');
  }
  
  return MyOutput(data: result);
}
```

### 4. Keep Business Logic Pure
Avoid HTTP concerns (request, response, headers) in your UseCase. Focus on business logic only:

```dart
// ✅ Good - Pure business logic
@override
Future<MyOutput> execute() async {
  final data = await _repository.getData();
  final processed = _processData(data);
  return MyOutput(result: processed);
}

// ❌ Bad - Mixed with HTTP concerns
@override
Future<MyOutput> execute() async {
  // Don't access request/response objects here
  final headers = request.headers; // ❌ No!
  // ...
}
```

### 5. Use Private Methods for Complex Logic
Break down complex operations into private helper methods:

```dart
@override
Future<MyOutput> execute() async {
  final validated = _validateInput();
  final processed = await _processData(validated);
  final formatted = _formatOutput(processed);
  
  return MyOutput(result: formatted);
}

bool _validateInput() {
  // Validation logic
}

Future<Data> _processData(Input data) async {
  // Processing logic
}

String _formatOutput(Data data) {
  // Formatting logic
}
```

---

## 📖 Additional Resources

- [USECASE_DTO_GUIDE.md](./USECASE_DTO_GUIDE.md) — Guide for creating Input/Output DTOs
- See `template/lib/modules/` for complete working examples
- Run `dart test` to see example tests in action

---

**Remember:** UseCases are the heart of your API. Keep them focused, testable, and independent of HTTP concerns!
