import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';
import '../../lib/modules/module2/usecases/usecase_2.dart';

void main() {
  group('UpperCase UseCase', () {
    test('should convert lowercase text to uppercase', () async {
      final input = {'text': 'hello world'};
      final handler = useCaseTestHandler(UpperCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should handle already uppercase text', () async {
      final input = {'text': 'HELLO WORLD'};
      final handler = useCaseTestHandler(UpperCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should handle mixed case text', () async {
      final input = {'text': 'HeLLo WoRLd'};
      final handler = useCaseTestHandler(UpperCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should handle empty string', () async {
      final input = {'text': ''};
      final handler = useCaseTestHandler(UpperCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should handle special characters', () async {
      final input = {'text': 'hello-world_2024!'};
      final handler = useCaseTestHandler(UpperCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should handle numbers', () async {
      final input = {'text': '12345'};
      final handler = useCaseTestHandler(UpperCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should handle unicode characters', () async {
      final input = {'text': 'café'};
      final handler = useCaseTestHandler(UpperCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });
  });
}
