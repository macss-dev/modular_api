/// RED — fromJson must validate required fields and types, returning 400.
///
/// fromJson validates structure (field presence + JSON type correctness).
/// validate() handles only business rules.
///
/// Error message contract (identical across all 3 SDKs for parity):
///   - Missing required field: "Missing required field: {name}"
///   - Wrong JSON type:        "Field '{name}' must be of type {type}"
library;

import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';

void main() {
  group('validateJsonFields', () {
    final fields = [
      SchemaField.string('name', description: 'Name'),
      SchemaField.integer('age', description: 'Age'),
    ];

    test('throws InputValidationException for missing required field', () {
      expect(
        () => validateJsonFields({}, fields),
        throwsA(isA<InputValidationException>().having(
          (e) => e.message,
          'message',
          'Missing required field: name',
        )),
      );
    });

    test('throws InputValidationException for null required field', () {
      expect(
        () => validateJsonFields({'name': null, 'age': 25}, fields),
        throwsA(isA<InputValidationException>().having(
          (e) => e.message,
          'message',
          'Missing required field: name',
        )),
      );
    });

    test('throws for wrong type — int where string expected', () {
      expect(
        () => validateJsonFields({'name': 123, 'age': 25}, fields),
        throwsA(isA<InputValidationException>().having(
          (e) => e.message,
          'message',
          "Field 'name' must be of type string",
        )),
      );
    });

    test('throws for wrong type — string where integer expected', () {
      expect(
        () =>
            validateJsonFields({'name': 'Alice', 'age': 'twenty-five'}, fields),
        throwsA(isA<InputValidationException>().having(
          (e) => e.message,
          'message',
          "Field 'age' must be of type integer",
        )),
      );
    });

    test('does not throw for valid JSON', () {
      expect(
        () => validateJsonFields({'name': 'Alice', 'age': 25}, fields),
        returnsNormally,
      );
    });

    test('skips validation for optional fields', () {
      final fieldsWithOptional = [
        SchemaField.string('name', description: 'Name'),
        SchemaField.optional(SchemaField.integer('age', description: 'Age')),
      ];
      expect(
        () => validateJsonFields({'name': 'Alice'}, fieldsWithOptional),
        returnsNormally,
      );
    });
  });

  group('validateJsonFields — object type', () {
    final fields = [
      SchemaField.string('id', description: 'ID'),
      SchemaField.object('details', description: 'Nested object'),
    ];

    test('accepts Map value for SchemaField.object', () {
      expect(
        () => validateJsonFields({
          'id': 'abc',
          'details': {'amount': 100, 'currency': 'PEN'},
        }, fields),
        returnsNormally,
      );
    });

    test('rejects String value for SchemaField.object', () {
      expect(
        () => validateJsonFields({'id': 'abc', 'details': 'not-a-map'}, fields),
        throwsA(isA<InputValidationException>().having(
          (e) => e.message,
          'message',
          "Field 'details' must be of type object",
        )),
      );
    });

    test('rejects List value for SchemaField.object', () {
      expect(
        () => validateJsonFields({
          'id': 'abc',
          'details': [1, 2]
        }, fields),
        throwsA(isA<InputValidationException>().having(
          (e) => e.message,
          'message',
          "Field 'details' must be of type object",
        )),
      );
    });
  });
}
