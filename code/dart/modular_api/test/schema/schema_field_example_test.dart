import 'package:test/test.dart';
import 'package:modular_api/src/core/schema/field.dart';

void main() {
  group('SchemaField example parameter', () {
    test('SchemaField.string stores example', () {
      final f = SchemaField.string('name', example: 'Sebastián');
      expect(f.example, 'Sebastián');
    });

    test('SchemaField.integer stores example', () {
      final f = SchemaField.integer('age', example: 25);
      expect(f.example, 25);
    });

    test('SchemaField.number stores example', () {
      final f = SchemaField.number('weight', example: 72.5);
      expect(f.example, 72.5);
    });

    test('SchemaField.boolean stores example', () {
      final f = SchemaField.boolean('active', example: true);
      expect(f.example, true);
    });

    test('SchemaField.array stores example', () {
      final f = SchemaField.array(
        'tags',
        SchemaField.string(''),
        example: ['dart', 'flutter'],
      );
      expect(f.example, ['dart', 'flutter']);
    });

    test('SchemaField.optional propagates example from inner', () {
      final inner = SchemaField.string('nick', example: 'Seb');
      final f = SchemaField.optional(inner);
      expect(f.example, 'Seb');
      expect(f.required, isFalse);
      expect(f.nullable, isTrue);
    });

    test('SchemaField without example has null', () {
      final f = SchemaField.string('name');
      expect(f.example, isNull);
    });
  });

  group('buildSchema emits example', () {
    test('includes example per property when present', () {
      final schema = buildSchema([
        SchemaField.string('name',
            description: 'Name to greet', example: 'Sebastián'),
        SchemaField.integer('age', description: 'User age', example: 25),
      ]);

      final nameProps = schema['properties']['name'] as Map;
      expect(nameProps['example'], 'Sebastián');

      final ageProps = schema['properties']['age'] as Map;
      expect(ageProps['example'], 25);
    });

    test('omits example when not provided', () {
      final schema = buildSchema([
        SchemaField.string('name', description: 'Name to greet'),
      ]);

      final nameProps = schema['properties']['name'] as Map;
      expect(nameProps.containsKey('example'), isFalse);
    });

    test('includes example for all types', () {
      final schema = buildSchema([
        SchemaField.string('s', example: 'hello'),
        SchemaField.integer('i', example: 42),
        SchemaField.number('n', example: 3.14),
        SchemaField.boolean('b', example: false),
        SchemaField.array('a', SchemaField.string(''), example: ['x', 'y']),
      ]);

      expect((schema['properties']['s'] as Map)['example'], 'hello');
      expect((schema['properties']['i'] as Map)['example'], 42);
      expect((schema['properties']['n'] as Map)['example'], 3.14);
      expect((schema['properties']['b'] as Map)['example'], false);
      expect((schema['properties']['a'] as Map)['example'], ['x', 'y']);
    });

    test('composes top-level example from per-field examples', () {
      final schema = buildSchema([
        SchemaField.string('name', example: 'Sebastián'),
        SchemaField.integer('age', example: 25),
      ]);

      expect(schema['example'], {'name': 'Sebastián', 'age': 25});
    });

    test('omits top-level example when no fields have examples', () {
      final schema = buildSchema([
        SchemaField.string('name'),
      ]);

      expect(schema.containsKey('example'), isFalse);
    });

    test('top-level example only includes fields that have examples', () {
      final schema = buildSchema([
        SchemaField.string('name', example: 'Sebastián'),
        SchemaField.integer('age'),
      ]);

      expect(schema['example'], {'name': 'Sebastián'});
    });
  });
}
