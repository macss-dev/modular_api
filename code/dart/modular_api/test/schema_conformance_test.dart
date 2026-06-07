import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:modular_api/src/core/usecase/usecase.dart';
import 'package:modular_api/src/core/schema/field.dart';

class HelloInput extends Input {
  final String name;
  HelloInput({required this.name});

  factory HelloInput.fromJson(Map<String, dynamic> json) =>
      HelloInput(name: (json['name'] ?? '').toString());

  @override
  Map<String, dynamic> toJson() => {'name': name};

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.string('name',
            description: 'Name to greet', example: 'World'),
      ];
}

class HelloOutput extends Output {
  final String message;
  HelloOutput({this.message = ''});

  @override
  int get statusCode => 200;

  @override
  Map<String, dynamic> toJson() => {'message': message};

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.string('message',
            description: 'Greeting message', example: 'Hello, World!'),
      ];
}

/// Loads a JSON fixture relative to the monorepo root.
Map<String, dynamic> loadFixture(String name) {
  final candidates = <String>[
    '${Directory.current.path}/../../tests/fixtures/$name',
    '${Directory.current.path}/../tests/fixtures/$name',
    '${Directory.current.path}/tests/fixtures/$name',
    '${Directory.current.path}/code/tests/fixtures/$name',
  ];

  for (final candidate in candidates) {
    final file = File(candidate);
    if (file.existsSync()) {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }
  }

  throw FileSystemException('Fixture not found', candidates.first);
}

void main() {
  group('Schema Conformance', () {
    test('HelloInput schema matches shared fixture', () {
      final fixture = loadFixture('hello_input_schema.json');
      final input = HelloInput(name: 'test');
      expect(input.toSchema(), equals(fixture));
    });

    test('HelloOutput schema matches shared fixture', () {
      final fixture = loadFixture('hello_output_schema.json');
      final output = HelloOutput(message: 'test');
      expect(output.toSchema(), equals(fixture));
    });
  });

  group('Schema Conformance — object type', () {
    test('WebhookInput schema matches shared fixture', () {
      final fixture = loadFixture('webhook_input_schema.json');
      final schema = buildSchema([
        SchemaField.string('instruction_id',
            description: 'Payment instruction ID', example: '20260323ABC'),
        SchemaField.object('transfer_details',
            description: 'Nested transfer info',
            example: {'amount': 2300, 'currency': 'PEN'}),
      ]);
      expect(schema, equals(fixture));
    });
  });
}
