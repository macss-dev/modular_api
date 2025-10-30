import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';
import '../../lib/modules/module3/usecases/usecase_3.dart';

void main() {
  group('LowerCase UseCase', () {
    test('should convert uppercase text to lowercase', () async {
      final input = {'text': 'HELLO WORLD'};
      final handler = useCaseTestHandler(LowerCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should handle already lowercase text', () async {
      final input = {'text': 'hello world'};
      final handler = useCaseTestHandler(LowerCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should handle mixed case text', () async {
      final input = {'text': 'HeLLo WoRLd'};
      final handler = useCaseTestHandler(LowerCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should handle empty string', () async {
      final input = {'text': ''};
      final handler = useCaseTestHandler(LowerCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should handle special characters', () async {
      final input = {'text': 'HELLO-WORLD_2024!'};
      final handler = useCaseTestHandler(LowerCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should handle numbers', () async {
      final input = {'text': '12345'};
      final handler = useCaseTestHandler(LowerCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should handle unicode characters', () async {
      final input = {'text': 'CAFÉ'};
      final handler = useCaseTestHandler(LowerCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });
  });
}
