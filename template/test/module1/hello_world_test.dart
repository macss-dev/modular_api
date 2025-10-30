import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';
import '../../lib/modules/module1/hello_world.dart';

void main() {
  group('HelloWorld UseCase', () {
    test('should return greeting with valid word', () async {
      final input = {'word': 'World'};
      final handler = useCaseTestHandler(HelloWorld.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should succeed with different words', () async {
      final input = {'word': 'Dart'};
      final handler = useCaseTestHandler(HelloWorld.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should succeed with special characters', () async {
      final input = {'word': 'API-2024'};
      final handler = useCaseTestHandler(HelloWorld.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should fail with empty word', () async {
      final input = {'word': ''};
      final handler = useCaseTestHandler(HelloWorld.fromJson);

      final result = await handler(input);

      expect(result, isFalse);
    });

    test('should handle missing word field', () async {
      final input = <String, dynamic>{};
      final handler = useCaseTestHandler(HelloWorld.fromJson);

      final result = await handler(input);

      expect(result, isFalse);
    });
  });
}
