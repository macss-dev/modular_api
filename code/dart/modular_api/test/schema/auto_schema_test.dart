import 'package:test/test.dart';
import 'package:modular_api/src/core/schema/field.dart';
import 'package:modular_api/src/core/usecase/usecase.dart';

// ── Test DTOs with schemaFields ──────────────────────────────

class NameInput extends Input {
  final String name;

  NameInput({required this.name});

  factory NameInput.fromJson(Map<String, dynamic> json) =>
      NameInput(name: (json['name'] ?? '').toString());

  @override
  Map<String, dynamic> toJson() => {'name': name};

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.string('name', description: 'Name to greet'),
      ];
}

class GreetOutput extends Output {
  final String message;

  GreetOutput({this.message = ''});

  @override
  int get statusCode => 200;

  @override
  Map<String, dynamic> toJson() => {'message': message};

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.string('message', description: 'Greeting message'),
      ];
}

class OptionalInput extends Input {
  final String name;

  final String? nickname;

  OptionalInput({required this.name, this.nickname});

  factory OptionalInput.fromJson(Map<String, dynamic> json) => OptionalInput(
        name: (json['name'] ?? '').toString(),
        nickname: json['nickname']?.toString(),
      );

  @override
  Map<String, dynamic> toJson() => {
        'name': name,
        if (nickname != null) 'nickname': nickname,
      };

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.string('name', description: 'Required name'),
        SchemaField.optional(
            SchemaField.string('nickname', description: 'Optional nickname')),
      ];
}

// ── Tests ────────────────────────────────────────────────────

void main() {
  group('SchemaField metadata', () {
    test('SchemaField.string() creates correct metadata', () {
      final field = SchemaField.string('name', description: 'test');
      expect(field.name, 'name');
      expect(field.type, 'string');
      expect(field.description, 'test');
      expect(field.required, true);
      expect(field.nullable, false);
    });

    test('SchemaField.integer() creates correct metadata', () {
      final field = SchemaField.integer('age', description: 'user age');
      expect(field.type, 'integer');
    });

    test('SchemaField.optional() marks field as not required and nullable', () {
      final field =
          SchemaField.optional(SchemaField.string('nick', description: 'opt'));
      expect(field.required, false);
      expect(field.nullable, true);
      expect(field.description, 'opt');
    });

    test('SchemaField.array() stores items type', () {
      final field = SchemaField.array(
        'tags',
        SchemaField.string('_item'),
        description: 'list of tags',
      );
      expect(field.type, 'array');
      expect(field.items?.type, 'string');
    });
  });

  group('buildSchema utility', () {
    test('builds correct OpenAPI schema from field list', () {
      final schema = buildSchema([
        SchemaField.string('name', description: 'Name to greet'),
      ]);
      expect(schema, {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': 'Name to greet'},
        },
        'required': ['name'],
      });
    });

    test('optional field excluded from required and marked nullable', () {
      final schema = buildSchema([
        SchemaField.string('name'),
        SchemaField.optional(SchemaField.string('nick')),
      ]);
      expect(schema['required'], ['name']);
      expect((schema['properties'] as Map)['nick'],
          {'type': 'string', 'nullable': true});
    });
  });

  group('Input auto-schema from schemaFields', () {
    test('toSchema() returns correct OpenAPI schema', () {
      final input = NameInput(name: 'Carlos');
      expect(input.toSchema(), {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': 'Name to greet'},
        },
        'required': ['name'],
      });
    });

    test('optional field schema works correctly', () {
      final input = OptionalInput(name: 'Carlos');
      final schema = input.toSchema();
      expect(schema['required'], ['name']);
      expect((schema['properties'] as Map)['nickname'], {
        'type': 'string',
        'description': 'Optional nickname',
        'nullable': true,
      });
    });
  });

  group('Output auto-schema from schemaFields', () {
    test('toSchema() returns correct OpenAPI schema', () {
      final output = GreetOutput(message: 'Hello!');
      expect(output.toSchema(), {
        'type': 'object',
        'properties': {
          'message': {'type': 'string', 'description': 'Greeting message'},
        },
        'required': ['message'],
      });
    });

    test('statusCode is still provided by subclass', () {
      final output = GreetOutput();
      expect(output.statusCode, 200);
    });
  });
}
