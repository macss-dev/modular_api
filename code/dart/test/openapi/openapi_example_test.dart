import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:modular_api/modular_api.dart';
import 'package:modular_api/src/core/modular_api.dart' show apiRegistry;
import 'package:test/test.dart';

// ── UseCase with examples (strict fromJson — no coercion) ────────────────

class _GreetInput extends Input {
  final String name;
  final int age;
  final double score;
  final bool active;
  final List<String> tags;

  _GreetInput({
    required this.name,
    required this.age,
    required this.score,
    required this.active,
    required this.tags,
  });

  static final example = _GreetInput(
    name: 'Sebastián',
    age: 25,
    score: 95.5,
    active: true,
    tags: ['dev', 'dart'],
  );

  factory _GreetInput.fromJson(Map<String, dynamic> json) => _GreetInput(
        name: json['name'],
        age: json['age'],
        score: (json['score'] as num).toDouble(),
        active: json['active'],
        tags: (json['tags'] as List).cast<String>(),
      );

  @override
  Map<String, dynamic> toJson() => {
        'name': name,
        'age': age,
        'score': score,
        'active': active,
        'tags': tags,
      };

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.string('name',
            description: 'Name to greet', example: 'Sebastián'),
        SchemaField.integer('age', example: 25),
        SchemaField.number('score', example: 95.5),
        SchemaField.boolean('active', example: true),
        SchemaField.array('tags', SchemaField.string(''),
            example: ['dev', 'dart']),
      ];
}

class _GreetOutput extends Output {
  final String message;

  _GreetOutput({this.message = ''});

  static final example = _GreetOutput(message: 'Hello, Sebastián!');

  @override
  int get statusCode => 200;

  @override
  Map<String, dynamic> toJson() => {'message': message};

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.string('message',
            description: 'Greeting message', example: 'Hello, Sebastián!'),
      ];
}

class _GreetUseCase implements UseCase<_GreetInput, _GreetOutput> {
  @override
  final _GreetInput input;
  @override
  ModularLogger? logger;

  _GreetUseCase({required this.input});

  static _GreetUseCase fromJson(Map<String, dynamic> json) =>
      _GreetUseCase(input: _GreetInput.fromJson(json));

  @override
  String? validate() => null;

  @override
  Future<_GreetOutput> execute() async {
    return _GreetOutput(message: 'Hello, ${input.name}!');
  }
}

void main() {
  group('ModuleBuilder.usecase with inputExample / outputExample', () {
    late HttpServer server;
    late int port;

    setUp(() async {
      apiRegistry.routes.clear();

      final api = ModularApi(
        basePath: '/api',
        title: 'Example API',
        version: '1.0.0',
      );

      api.module('greetings', (m) {
        m.usecase(
          'hello',
          _GreetUseCase.fromJson,
          inputExample: _GreetInput.example,
          outputExample: _GreetOutput.example,
        );
      });

      server = await api.serve(port: 0);
      port = server.port;
    });

    tearDown(() async {
      await server.close(force: true);
      apiRegistry.routes.clear();
    });

    test('OpenAPI spec contains example on input schema', () async {
      final resp =
          await http.get(Uri.parse('http://localhost:$port/api/openapi.json'));
      final spec = jsonDecode(resp.body) as Map<String, dynamic>;
      final schemas = (spec['components'] as Map)['schemas'] as Map;
      final inputSchema = schemas['greetings_hello_Input'] as Map;

      expect(inputSchema['example'], {
        'name': 'Sebastián',
        'age': 25,
        'score': 95.5,
        'active': true,
        'tags': ['dev', 'dart'],
      });
    });

    test('OpenAPI spec contains example on output schema', () async {
      final resp =
          await http.get(Uri.parse('http://localhost:$port/api/openapi.json'));
      final spec = jsonDecode(resp.body) as Map<String, dynamic>;
      final schemas = (spec['components'] as Map)['schemas'] as Map;
      final outputSchema = schemas['greetings_hello_Output'] as Map;

      expect(outputSchema['example'], {
        'message': 'Hello, Sebastián!',
      });
    });

    test('OpenAPI schema has correct types for all fields', () async {
      final resp =
          await http.get(Uri.parse('http://localhost:$port/api/openapi.json'));
      final spec = jsonDecode(resp.body) as Map<String, dynamic>;
      final schemas = (spec['components'] as Map)['schemas'] as Map;
      final props =
          (schemas['greetings_hello_Input'] as Map)['properties'] as Map;

      expect(props['name']['type'], 'string');
      expect(props['age']['type'], 'integer');
      expect(props['score']['type'], 'number');
      expect(props['active']['type'], 'boolean');
      expect(props['tags']['type'], 'array');
      expect(props['tags']['items'], {'type': 'string'});
    });

    test('schema extraction uses example not factory({})', () async {
      // _GreetInput.fromJson is STRICT (no ?? coercion).
      // If OpenAPI tried factory({}) it would throw TypeError.
      // Test passing proves schema came from the example instance.
      final resp =
          await http.get(Uri.parse('http://localhost:$port/api/openapi.json'));
      final spec = jsonDecode(resp.body) as Map<String, dynamic>;
      final schemas = (spec['components'] as Map)['schemas'] as Map;

      final inputSchema = schemas['greetings_hello_Input'] as Map;
      expect(inputSchema['properties'], isNotEmpty);
      expect(inputSchema['required'], isNotEmpty);
    });
  });
}
