import 'package:test/test.dart';
import 'package:modular_api/src/core/schema/field.dart';
import 'package:modular_api/src/core/usecase/usecase.dart';

// ── Input WITHOUT schemaFields — relies on toJson() inference ─────────────

class BareInput extends Input {
  final String name;
  final int age;
  final double score;
  final bool active;
  final List<String> tags;

  BareInput({
    required this.name,
    required this.age,
    required this.score,
    required this.active,
    required this.tags,
  });

  @override
  Map<String, dynamic> toJson() => {
        'name': name,
        'age': age,
        'score': score,
        'active': active,
        'tags': tags,
      };
}

// ── Input WITH schemaFields — has descriptions ────────────────────────────

class DescribedInput extends Input {
  final String name;

  DescribedInput({required this.name});

  @override
  Map<String, dynamic> toJson() => {'name': name};

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.string('name', description: 'Name to greet'),
      ];
}

// ── Output WITHOUT schemaFields ───────────────────────────────────────────

class BareOutput extends Output {
  final String message;

  BareOutput({required this.message});

  @override
  int get statusCode => 200;

  @override
  Map<String, dynamic> toJson() => {'message': message};
}

void main() {
  group('Input.toSchema() fallback to inferSchemaFromExample', () {
    test('Input without schemaFields infers schema from toJson()', () {
      final input = BareInput(
        name: 'Sebastián',
        age: 25,
        score: 95.5,
        active: true,
        tags: ['dev', 'dart'],
      );
      final schema = input.toSchema();

      expect(schema['type'], 'object');
      expect(schema['properties']['name'], {'type': 'string'});
      expect(schema['properties']['age'], {'type': 'integer'});
      expect(schema['properties']['score'], {'type': 'number'});
      expect(schema['properties']['active'], {'type': 'boolean'});
      expect(schema['properties']['tags'], {
        'type': 'array',
        'items': {'type': 'string'},
      });
      expect(
        schema['required'],
        unorderedEquals(['name', 'age', 'score', 'active', 'tags']),
      );
    });

    test('Input with schemaFields uses buildSchema (preferred path)', () {
      final input = DescribedInput(name: 'World');
      final schema = input.toSchema();

      expect(schema['properties']['name']['description'], 'Name to greet');
      expect(schema['properties']['name']['type'], 'string');
    });
  });

  group('Output.toSchema() fallback to inferSchemaFromExample', () {
    test('Output without schemaFields infers schema from toJson()', () {
      final output = BareOutput(message: 'Hello!');
      final schema = output.toSchema();

      expect(schema['type'], 'object');
      expect(schema['properties']['message'], {'type': 'string'});
      expect(schema['required'], ['message']);
    });
  });
}
