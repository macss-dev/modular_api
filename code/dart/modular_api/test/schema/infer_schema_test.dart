import 'package:test/test.dart';
import 'package:modular_api/src/core/schema/field.dart';

void main() {
  group('inferSchemaFromExample', () {
    test('String value infers type string', () {
      final schema = inferSchemaFromExample({'name': 'Sebastián'});
      expect(schema['properties']['name'], {'type': 'string'});
      expect(schema['required'], ['name']);
    });

    test('int value infers type integer', () {
      final schema = inferSchemaFromExample({'age': 25});
      expect(schema['properties']['age'], {'type': 'integer'});
      expect(schema['required'], ['age']);
    });

    test('double value infers type number', () {
      final schema = inferSchemaFromExample({'weight': 72.5});
      expect(schema['properties']['weight'], {'type': 'number'});
      expect(schema['required'], ['weight']);
    });

    test('bool value infers type boolean', () {
      final schema = inferSchemaFromExample({'active': true});
      expect(schema['properties']['active'], {'type': 'boolean'});
      expect(schema['required'], ['active']);
    });

    test('List<String> infers array with string items', () {
      final schema = inferSchemaFromExample({
        'tags': ['dart', 'flutter'],
      });
      expect(schema['properties']['tags'], {
        'type': 'array',
        'items': {'type': 'string'},
      });
      expect(schema['required'], ['tags']);
    });

    test('List<int> infers array with integer items', () {
      final schema = inferSchemaFromExample({
        'scores': [10, 20, 30],
      });
      expect(schema['properties']['scores'], {
        'type': 'array',
        'items': {'type': 'integer'},
      });
    });

    test('List<double> infers array with number items', () {
      final schema = inferSchemaFromExample({
        'rates': [1.5, 2.5],
      });
      expect(schema['properties']['rates'], {
        'type': 'array',
        'items': {'type': 'number'},
      });
    });

    test('List<bool> infers array with boolean items', () {
      final schema = inferSchemaFromExample({
        'flags': [true, false],
      });
      expect(schema['properties']['flags'], {
        'type': 'array',
        'items': {'type': 'boolean'},
      });
    });

    test('empty List infers array with string items (default)', () {
      final schema = inferSchemaFromExample({'items': <dynamic>[]});
      expect(schema['properties']['items'], {
        'type': 'array',
        'items': {'type': 'string'},
      });
    });

    test('null value infers nullable string not required', () {
      final schema = inferSchemaFromExample({'nickname': null});
      expect(schema['properties']['nickname'], {
        'type': 'string',
        'nullable': true,
      });
      expect(schema['required'], isNot(contains('nickname')));
    });

    test('mixed DTO with all types', () {
      final schema = inferSchemaFromExample({
        'name': 'Sebastián',
        'age': 25,
        'weight': 72.5,
        'active': true,
        'tags': ['dev', 'dart'],
        'nickname': null,
      });

      expect(schema['type'], 'object');
      expect(schema['properties']['name'], {'type': 'string'});
      expect(schema['properties']['age'], {'type': 'integer'});
      expect(schema['properties']['weight'], {'type': 'number'});
      expect(schema['properties']['active'], {'type': 'boolean'});
      expect(schema['properties']['tags'], {
        'type': 'array',
        'items': {'type': 'string'},
      });
      expect(schema['properties']['nickname'], {
        'type': 'string',
        'nullable': true,
      });
      expect(
        schema['required'],
        unorderedEquals(['name', 'age', 'weight', 'active', 'tags']),
      );
    });

    test('schema always has type object', () {
      final schema = inferSchemaFromExample({'x': 1});
      expect(schema['type'], 'object');
    });

    test('empty map produces empty schema', () {
      final schema = inferSchemaFromExample({});
      expect(schema['type'], 'object');
      expect(schema['properties'], {});
      expect(schema.containsKey('required'), isFalse);
    });
  });
}
