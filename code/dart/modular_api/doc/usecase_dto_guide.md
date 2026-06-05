# UseCase Input/Output DTO Guide

This guide provides clear and precise instructions for creating `Input` and `Output` DTOs for use cases in the `modular_api` framework.

---

## 📋 Overview

Every use case requires two DTO classes:
- **Input** — extends `Input` base class, represents the request data
- **Output** — extends `Output` base class, represents the response data

Each DTO must implement:
1. `fromJson` — factory constructor to deserialize from JSON
2. `toJson` — method to serialize to JSON
3. `schemaFields` — getter that returns field metadata for automatic OpenAPI schema generation

The `schemaFields` getter returns field metadata for automatic OpenAPI schema generation.

Schema generation is driven by the `schemaFields` getter and `SchemaField` metadata.

---

## 🎯 Step-by-Step Guide

### Step 1: Define your data class

Start by defining the properties for your Input and Output classes.

**Example:**
```dart
class CasoInput {
  int valor;
  String valor2;
  double valor3;
}

class CasoOutput {
  int valor;
  String valor2;
  double valor3;
}
```

### Step 2: Implement the Input class

```dart
import 'package:modular_api/modular_api.dart';

class CasoInput extends Input {
  final int valor;

  final String valor2;

  final double valor3;

  CasoInput({
    required this.valor,
    required this.valor2,
    required this.valor3,
  });

  factory CasoInput.fromJson(Map<String, dynamic> json) {
    return CasoInput(
      valor: json['valor'] as int,
      valor2: json['valor2'] as String,
      valor3: (json['valor3'] as num).toDouble(),
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'valor': valor,
      'valor2': valor2,
      'valor3': valor3,
    };
  }

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.integer('valor', description: 'Integer value'),
        SchemaField.string('valor2', description: 'String value'),
        SchemaField.number('valor3', description: 'Double value'),
      ];
}
```

### Step 3: Implement the Output class

```dart
import 'package:modular_api/modular_api.dart';

class CasoOutput extends Output {
  final int valor;

  final String valor2;

  final double valor3;

  CasoOutput({
    required this.valor,
    required this.valor2,
    required this.valor3,
  });

  factory CasoOutput.fromJson(Map<String, dynamic> json) {
    return CasoOutput(
      valor: json['valor'] as int,
      valor2: json['valor2'] as String,
      valor3: (json['valor3'] as num).toDouble(),
    );
  }

  @override
  int get statusCode => 200;

  @override
  Map<String, dynamic> toJson() {
    return {
      'valor': valor,
      'valor2': valor2,
      'valor3': valor3,
    };
  }

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.integer('valor', description: 'Integer value'),
        SchemaField.string('valor2', description: 'String value'),
        SchemaField.number('valor3', description: 'Double value'),
      ];
}
```

---

## 📚 Type Mapping Reference

Use this table to map Dart types to `SchemaField` factories:

| Dart Type | SchemaField Factory | OpenAPI Type |
|-----------|-------------------|-------------|
| `int` | `SchemaField.integer()` | `integer` |
| `double` | `SchemaField.number()` | `number` |
| `String` | `SchemaField.string()` | `string` |
| `bool` | `SchemaField.boolean()` | `boolean` |
| `List<T>` | `SchemaField.array()` | `array` with `items` |
| Nullable (`T?`) | Add `nullable: true` to any factory | Excluded from `required[]`, `nullable: true` |

---

## 🔧 Advanced Examples

### Example 1: Optional Fields

```dart
class ProductInput extends Input {
  final String name;

  final double price;

  final String? description;

  final int? stock;

  ProductInput({
    required this.name,
    required this.price,
    this.description,
    this.stock,
  });

  factory ProductInput.fromJson(Map<String, dynamic> json) {
    return ProductInput(
      name: json['name'] as String,
      price: (json['price'] as num).toDouble(),
      description: json['description'] as String?,
      stock: json['stock'] as int?,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'price': price,
      if (description != null) 'description': description,
      if (stock != null) 'stock': stock,
    };
  }

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.string('name', description: 'Product name'),
        SchemaField.number('price', description: 'Product price'),
        SchemaField.string('description', description: 'Product description (optional)', nullable: true),
        SchemaField.integer('stock', description: 'Available stock (optional)', nullable: true),
      ];
}
```

### Example 2: Array Fields

```dart
class UserInput extends Input {
  final String name;

  final List<String> roles;

  UserInput({required this.name, required this.roles});

  factory UserInput.fromJson(Map<String, dynamic> json) {
    return UserInput(
      name: json['name'] as String,
      roles: (json['roles'] as List<dynamic>).map((e) => e as String).toList(),
    );
  }

  @override
  Map<String, dynamic> toJson() => {'name': name, 'roles': roles};

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.string('name', description: 'User name'),
        SchemaField.array('roles', items: {'type': 'string'}, description: 'User roles'),
      ];
}
```

---

## ⚠️ Migration from Manual `toSchema()`

If your DTOs currently override `toSchema()` manually, you can migrate to the `schemaFields` pattern:

1. **Add `schemaFields` getter** — Declare each field as a `SchemaField` with the appropriate factory
2. **Remove `toSchema()` override** — The base class `toSchema()` calls `buildSchema(schemaFields)` automatically
3. **Change `implements` to `extends`** — Use `extends Input`/`extends Output` instead of `implements`

**Before (manual):**
```dart
class MyInput implements Input {
  final String name;
  // ... fromJson, toJson ...
  
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

**After (auto-schema):**
```dart
class MyInput extends Input {
  final String name;
  // ... fromJson, toJson ...

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.string('name', description: 'User name'),
      ];
}
```

> **Note:** Manual `toSchema()` overrides still work but are deprecated. Use the `schemaFields` getter instead.

---

## ✅ Checklist

When creating or updating Input/Output DTOs, ensure:

- [ ] Class extends `Input` or `Output` (not `implements`)
- [ ] All properties are `final`
- [ ] `fromJson` factory constructor is implemented
- [ ] `toJson` method is implemented and overrides base class
- [ ] `schemaFields` getter is implemented with `SchemaField` entries for each field
- [ ] SchemaField factory matches Dart type (see Type Mapping Reference)
- [ ] Nullable fields use `nullable: true` in their `SchemaField`
- [ ] Optional fields use nullable Dart types (`Type?`)
- [ ] Descriptions are provided for all fields
- [ ] Nested objects implement their own `fromJson` and `toJson` methods
- [ ] Lists are properly handled with `.map()` in `fromJson`
- [ ] DateTime fields use `DateTime.parse()` and `.toIso8601String()`

---

## 🚀 Quick Template

Copy and adapt this template for new DTOs:

```dart
import 'package:modular_api/modular_api.dart';

class MyUseCaseInput extends Input {
  final String myField;

  MyUseCaseInput({required this.myField});

  factory MyUseCaseInput.fromJson(Map<String, dynamic> json) {
    return MyUseCaseInput(myField: json['myField'] as String);
  }

  @override
  Map<String, dynamic> toJson() => {'myField': myField};

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.string('myField', description: 'Description here'),
      ];
}

class MyUseCaseOutput extends Output {
  final String result;

  MyUseCaseOutput({required this.result});

  factory MyUseCaseOutput.fromJson(Map<String, dynamic> json) {
    return MyUseCaseOutput(result: json['result'] as String);
  }

  @override
  int get statusCode => 200;

  @override
  Map<String, dynamic> toJson() => {'result': result};

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.string('result', description: 'Description here'),
      ];
}
```

---

## 📖 Additional Resources

- [OpenAPI Specification - Data Types](https://swagger.io/specification/#data-types)
- [JSON Schema Validation](https://json-schema.org/understanding-json-schema/reference/type.html)
- See `example/example.dart` for a working example in this repository

---

**Remember:** The `schemaFields` getter is the single source of truth for OpenAPI schema generation. Keep it synchronized with your class properties!
