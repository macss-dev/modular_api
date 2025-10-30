# UseCase Input/Output DTO Guide

This guide provides clear and precise instructions for creating `Input` and `Output` DTOs for use cases in the `modular_api` framework.

---

## 📋 Overview

Every use case requires two DTO classes:
- **Input** — extends `Input` base class, represents the request data
- **Output** — extends `Output` base class, represents the response data

Each DTO must implement:
1. `fromJson` — constructor to deserialize from JSON
2. `toJson` — method to serialize to JSON
3. `toSchema` — method to generate OpenAPI schema definition

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

  // fromJson constructor - deserialize from JSON
  factory CasoInput.fromJson(Map<String, dynamic> json) {
    return CasoInput(
      valor: json['valor'] as int,
      valor2: json['valor2'] as String,
      valor3: (json['valor3'] as num).toDouble(),
    );
  }

  // toJson method - serialize to JSON
  @override
  Map<String, dynamic> toJson() {
    return {
      'valor': valor,
      'valor2': valor2,
      'valor3': valor3,
    };
  }

  // toSchema method - generate OpenAPI schema
  @override
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'valor': {'type': 'integer', 'description': 'Integer value'},
        'valor2': {'type': 'string', 'description': 'String value'},
        'valor3': {'type': 'number', 'format': 'double', 'description': 'Double value'},
      },
      'required': ['valor', 'valor2', 'valor3'],
    };
  }
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

  // fromJson constructor - deserialize from JSON
  factory CasoOutput.fromJson(Map<String, dynamic> json) {
    return CasoOutput(
      valor: json['valor'] as int,
      valor2: json['valor2'] as String,
      valor3: (json['valor3'] as num).toDouble(),
    );
  }

  // toJson method - serialize to JSON
  @override
  Map<String, dynamic> toJson() {
    return {
      'valor': valor,
      'valor2': valor2,
      'valor3': valor3,
    };
  }

  // toSchema method - generate OpenAPI schema
  @override
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'valor': {'type': 'integer', 'description': 'Integer value'},
        'valor2': {'type': 'string', 'description': 'String value'},
        'valor3': {'type': 'number', 'format': 'double', 'description': 'Double value'},
      },
      'required': ['valor', 'valor2', 'valor3'],
    };
  }
}
```

---

## 📚 Type Mapping Reference

Use this table to map Dart types to OpenAPI schema types in `toSchema()`:

| Dart Type | OpenAPI Type | Format (optional) | Example |
|-----------|--------------|-------------------|---------|
| `int` | `'integer'` | `'int32'` or `'int64'` | `{'type': 'integer'}` |
| `double` | `'number'` | `'double'` | `{'type': 'number', 'format': 'double'}` |
| `num` | `'number'` | — | `{'type': 'number'}` |
| `String` | `'string'` | — | `{'type': 'string'}` |
| `bool` | `'boolean'` | — | `{'type': 'boolean'}` |
| `DateTime` | `'string'` | `'date-time'` | `{'type': 'string', 'format': 'date-time'}` |
| `List<T>` | `'array'` | — | `{'type': 'array', 'items': {...}}` |
| `Map<String, dynamic>` | `'object'` | — | `{'type': 'object'}` |
| Custom Object | `'object'` | — | `{'type': 'object', 'properties': {...}}` |

---

## 🔧 Advanced Examples

### Example 1: Complex Input with Lists and Nested Objects

```dart
class UserInput extends Input {
  final String name;
  final int age;
  final List<String> roles;
  final Address address;

  UserInput({
    required this.name,
    required this.age,
    required this.roles,
    required this.address,
  });

  factory UserInput.fromJson(Map<String, dynamic> json) {
    return UserInput(
      name: json['name'] as String,
      age: json['age'] as int,
      roles: (json['roles'] as List<dynamic>).map((e) => e as String).toList(),
      address: Address.fromJson(json['address'] as Map<String, dynamic>),
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'age': age,
      'roles': roles,
      'address': address.toJson(),
    };
  }

  @override
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'name': {'type': 'string', 'description': 'User name'},
        'age': {'type': 'integer', 'description': 'User age'},
        'roles': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'User roles'
        },
        'address': {
          'type': 'object',
          'properties': {
            'street': {'type': 'string'},
            'city': {'type': 'string'},
            'zipCode': {'type': 'string'},
          },
          'required': ['street', 'city', 'zipCode'],
          'description': 'User address'
        },
      },
      'required': ['name', 'age', 'roles', 'address'],
    };
  }
}

class Address {
  final String street;
  final String city;
  final String zipCode;

  Address({required this.street, required this.city, required this.zipCode});

  factory Address.fromJson(Map<String, dynamic> json) {
    return Address(
      street: json['street'] as String,
      city: json['city'] as String,
      zipCode: json['zipCode'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'street': street,
      'city': city,
      'zipCode': zipCode,
    };
  }
}
```

### Example 2: Optional Fields

```dart
class ProductInput extends Input {
  final String name;
  final double price;
  final String? description; // Optional field
  final int? stock; // Optional field

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
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'name': {'type': 'string', 'description': 'Product name'},
        'price': {'type': 'number', 'format': 'double', 'description': 'Product price'},
        'description': {'type': 'string', 'description': 'Product description (optional)'},
        'stock': {'type': 'integer', 'description': 'Available stock (optional)'},
      },
      'required': ['name', 'price'], // Only required fields listed
    };
  }
}
```

### Example 3: DateTime Fields

```dart
class EventInput extends Input {
  final String title;
  final DateTime startDate;
  final DateTime? endDate; // Optional

  EventInput({
    required this.title,
    required this.startDate,
    this.endDate,
  });

  factory EventInput.fromJson(Map<String, dynamic> json) {
    return EventInput(
      title: json['title'] as String,
      startDate: DateTime.parse(json['startDate'] as String),
      endDate: json['endDate'] != null ? DateTime.parse(json['endDate'] as String) : null,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'startDate': startDate.toIso8601String(),
      if (endDate != null) 'endDate': endDate!.toIso8601String(),
    };
  }

  @override
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'title': {'type': 'string', 'description': 'Event title'},
        'startDate': {
          'type': 'string',
          'format': 'date-time',
          'description': 'Event start date and time'
        },
        'endDate': {
          'type': 'string',
          'format': 'date-time',
          'description': 'Event end date and time (optional)'
        },
      },
      'required': ['title', 'startDate'],
    };
  }
}
```

---

## ⚠️ Important: Updating Existing toSchema

**If a `toSchema` method already exists**, you must update it to accurately reflect the current class properties:

1. **Add new properties** — Add entries in the `properties` map for any new fields
2. **Remove obsolete properties** — Delete entries for fields that no longer exist
3. **Update types** — Ensure the OpenAPI type matches the Dart type (see Type Mapping Reference)
4. **Update required array** — Add/remove field names based on whether they are required or optional
5. **Update descriptions** — Keep descriptions accurate and helpful

**Example of updating an existing schema:**

Before (outdated):
```dart
@override
Map<String, dynamic> toSchema() {
  return {
    'type': 'object',
    'properties': {
      'name': {'type': 'string'},
      'age': {'type': 'integer'},
    },
    'required': ['name', 'age'],
  };
}
```

After (updated with new fields):
```dart
@override
Map<String, dynamic> toSchema() {
  return {
    'type': 'object',
    'properties': {
      'name': {'type': 'string', 'description': 'User name'},
      'age': {'type': 'integer', 'description': 'User age'},
      'email': {'type': 'string', 'format': 'email', 'description': 'User email'}, // NEW
      'verified': {'type': 'boolean', 'description': 'Email verification status'}, // NEW
    },
    'required': ['name', 'age', 'email'], // Updated to include 'email', 'verified' is optional
  };
}
```

---

## ✅ Checklist

When creating or updating Input/Output DTOs, ensure:

- [ ] Class extends `Input` or `Output`
- [ ] All properties are `final`
- [ ] `fromJson` factory constructor is implemented
- [ ] `toJson` method is implemented and overrides base class
- [ ] `toSchema` method is implemented and overrides base class
- [ ] All properties are included in `fromJson`, `toJson`, and `toSchema`
- [ ] Type mapping in `toSchema` matches Dart types (see Type Mapping Reference)
- [ ] `required` array in `toSchema` includes only non-nullable fields
- [ ] Optional fields use nullable types (`Type?`) in Dart
- [ ] Descriptions are provided for all properties in `toSchema`
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
  // Add more fields here

  MyUseCaseInput({
    required this.myField,
    // Add more parameters here
  });

  factory MyUseCaseInput.fromJson(Map<String, dynamic> json) {
    return MyUseCaseInput(
      myField: json['myField'] as String,
      // Parse more fields here
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'myField': myField,
      // Add more fields here
    };
  }

  @override
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'myField': {'type': 'string', 'description': 'Description here'},
        // Add more properties here
      },
      'required': ['myField'], // List required fields
    };
  }
}

class MyUseCaseOutput extends Output {
  final String result;
  // Add more fields here

  MyUseCaseOutput({
    required this.result,
    // Add more parameters here
  });

  factory MyUseCaseOutput.fromJson(Map<String, dynamic> json) {
    return MyUseCaseOutput(
      result: json['result'] as String,
      // Parse more fields here
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'result': result,
      // Add more fields here
    };
  }

  @override
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'result': {'type': 'string', 'description': 'Description here'},
        // Add more properties here
      },
      'required': ['result'], // List required fields
    };
  }
}
```

---

## 📖 Additional Resources

- [OpenAPI Specification - Data Types](https://swagger.io/specification/#data-types)
- [JSON Schema Validation](https://json-schema.org/understanding-json-schema/reference/type.html)
- See `template/lib/modules/module1/hello_world.dart` for a working example in this repository

---

**Remember:** The `toSchema` method is critical for automatic OpenAPI documentation generation. Always keep it synchronized with your class properties!
