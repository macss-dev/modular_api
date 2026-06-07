import 'dart:convert';
import 'package:test/test.dart';
import 'package:shelf/shelf.dart';
import 'package:modular_api/src/core/schema/field.dart';
import 'package:modular_api/src/core/logger/logger.dart';
import 'package:modular_api/src/core/usecase/usecase.dart';
import 'package:modular_api/src/core/usecase/usecase_http_handler.dart';

// ── Strict UseCase: fromJson THROWS on missing/wrong types ──

class StrictInput extends Input {
  final String name;
  final int age;
  final double score;
  final bool active;
  final List<String> tags;

  StrictInput({
    required this.name,
    required this.age,
    required this.score,
    required this.active,
    required this.tags,
  });

  /// Strict factory — no coercion, no defaults.
  /// Will throw if fields are missing or wrong type.
  factory StrictInput.fromJson(Map<String, dynamic> json) {
    return StrictInput(
      name: json['name'] as String,
      age: json['age'] as int,
      score: json['score'] as double,
      active: json['active'] as bool,
      tags: (json['tags'] as List).cast<String>(),
    );
  }

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
        SchemaField.string('name', example: 'Alice'),
        SchemaField.integer('age', example: 30),
        SchemaField.number('score', example: 9.5),
        SchemaField.boolean('active', example: true),
        SchemaField.array('tags', SchemaField.string('item'),
            example: ['dart']),
      ];

  static StrictInput get example => StrictInput(
        name: 'Alice',
        age: 30,
        score: 9.5,
        active: true,
        tags: ['dart'],
      );
}

class StrictOutput extends Output {
  final String greeting;

  StrictOutput({required this.greeting});

  @override
  int get statusCode => 200;

  @override
  Map<String, dynamic> toJson() => {'greeting': greeting};

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.string('greeting', example: 'Hello Alice'),
      ];
}

class StrictUseCase implements UseCase<StrictInput, StrictOutput> {
  @override
  final StrictInput input;

  @override
  ModularLogger? logger;

  StrictUseCase({required this.input});

  factory StrictUseCase.fromJson(Map<String, dynamic> json) {
    return StrictUseCase(input: StrictInput.fromJson(json));
  }

  @override
  String? validate() => null;

  @override
  Future<StrictOutput> execute() async {
    return StrictOutput(greeting: 'Hello ${input.name}');
  }
}

// ── Helpers ──

Request _postRequest(Map<String, dynamic> body) {
  return Request(
    'POST',
    Uri.parse('http://localhost/test'),
    body: jsonEncode(body),
    headers: {'content-type': 'application/json'},
  );
}

void main() {
  group('Handler pre-validation with inputExample', () {
    late Handler handler;

    setUp(() {
      handler = useCaseHttpHandler(
        StrictUseCase.fromJson,
        inputExample: StrictInput.example,
      );
    });

    // ── Missing required fields ──

    test('returns 400 when required field is missing', () async {
      final res = await handler(_postRequest({
        // 'name' is missing
        'age': 30,
        'score': 9.5,
        'active': true,
        'tags': ['dart'],
      }));

      expect(res.statusCode, equals(400));
      final body = jsonDecode(await res.readAsString());
      expect(body['error'], contains('Missing required field: name'));
    });

    // ── Wrong types ──

    test('returns 400 when string field receives int', () async {
      final res = await handler(_postRequest({
        'name': 123, // should be String
        'age': 30,
        'score': 9.5,
        'active': true,
        'tags': ['dart'],
      }));

      expect(res.statusCode, equals(400));
      final body = jsonDecode(await res.readAsString());
      expect(body['error'], contains("Field 'name' must be of type string"));
    });

    test('returns 400 when integer field receives string', () async {
      final res = await handler(_postRequest({
        'name': 'Alice',
        'age': 'thirty', // should be int
        'score': 9.5,
        'active': true,
        'tags': ['dart'],
      }));

      expect(res.statusCode, equals(400));
      final body = jsonDecode(await res.readAsString());
      expect(body['error'], contains("Field 'age' must be of type integer"));
    });

    test('returns 400 when number field receives string', () async {
      final res = await handler(_postRequest({
        'name': 'Alice',
        'age': 30,
        'score': 'high', // should be double/num
        'active': true,
        'tags': ['dart'],
      }));

      expect(res.statusCode, equals(400));
      final body = jsonDecode(await res.readAsString());
      expect(body['error'], contains("Field 'score' must be of type number"));
    });

    test('returns 400 when boolean field receives string', () async {
      final res = await handler(_postRequest({
        'name': 'Alice',
        'age': 30,
        'score': 9.5,
        'active': 'yes', // should be bool
        'tags': ['dart'],
      }));

      expect(res.statusCode, equals(400));
      final body = jsonDecode(await res.readAsString());
      expect(body['error'], contains("Field 'active' must be of type boolean"));
    });

    test('returns 400 when array field receives string', () async {
      final res = await handler(_postRequest({
        'name': 'Alice',
        'age': 30,
        'score': 9.5,
        'active': true,
        'tags': 'dart', // should be List
      }));

      expect(res.statusCode, equals(400));
      final body = jsonDecode(await res.readAsString());
      expect(body['error'], contains("Field 'tags' must be of type array"));
    });

    // ── Valid data → success ──

    test('returns 200 with valid data (strict fromJson works)', () async {
      final res = await handler(_postRequest({
        'name': 'Alice',
        'age': 30,
        'score': 9.5,
        'active': true,
        'tags': ['dart'],
      }));

      expect(res.statusCode, equals(200));
      final body = jsonDecode(await res.readAsString());
      expect(body['greeting'], equals('Hello Alice'));
    });

    // ── Pre-validation protects strict fromJson ──

    test('pre-validates BEFORE fromJson — strict factory never crashes',
        () async {
      // Without pre-validation, this would crash in StrictInput.fromJson
      // because 'age' is a String, not int → `as int` would throw TypeError.
      // With pre-validation, handler returns 400 cleanly.
      final res = await handler(_postRequest({
        'name': 'Alice',
        'age': 'not-a-number',
        'score': 9.5,
        'active': true,
        'tags': ['dart'],
      }));

      expect(res.statusCode, equals(400));
      // Must NOT be 500 (which would mean fromJson crashed)
      final body = jsonDecode(await res.readAsString());
      expect(body['error'], isNot(contains('Internal server error')));
    });

    // ── Empty body → first missing field ──

    test('returns 400 on empty body (first missing field)', () async {
      final res = await handler(_postRequest({}));

      expect(res.statusCode, equals(400));
      final body = jsonDecode(await res.readAsString());
      expect(body['error'], contains('Missing required field'));
    });
  });

  group('Handler backward-compat — no inputExample', () {
    late Handler handler;

    setUp(() {
      // No inputExample — old behavior (post-validation)
      handler = useCaseHttpHandler(StrictUseCase.fromJson);
    });

    test('without inputExample, strict fromJson crashes yield 500', () async {
      // Without pre-validation, wrong types cause TypeError in fromJson → 500
      final res = await handler(_postRequest({
        'name': 123, // wrong type → as String throws
        'age': 30,
        'score': 9.5,
        'active': true,
        'tags': ['dart'],
      }));

      // 500 because fromJson crashes before validation can run
      expect(res.statusCode, equals(500));
    });
  });
}
