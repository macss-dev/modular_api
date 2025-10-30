import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';
import '../../lib/modules/module3/usecases/usecase_4.dart';

void main() {
  group('MultiplyCase UseCase', () {
    test('should multiply two positive numbers', () async {
      final input = {'x': 5, 'y': 3};
      final handler = useCaseTestHandler(MultiplyCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should multiply by zero', () async {
      final input = {'x': 10, 'y': 0};
      final handler = useCaseTestHandler(MultiplyCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should multiply zero by zero', () async {
      final input = {'x': 0, 'y': 0};
      final handler = useCaseTestHandler(MultiplyCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should multiply decimal numbers', () async {
      final input = {'x': 2.5, 'y': 4.0};
      final handler = useCaseTestHandler(MultiplyCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should multiply large numbers', () async {
      final input = {'x': 1000, 'y': 2000};
      final handler = useCaseTestHandler(MultiplyCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should multiply negative numbers', () async {
      final input = {'x': -5, 'y': 3};
      final handler = useCaseTestHandler(MultiplyCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should multiply two negative numbers', () async {
      final input = {'x': -5, 'y': -3};
      final handler = useCaseTestHandler(MultiplyCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should handle string numbers', () async {
      final input = {'x': '6', 'y': '7'};
      final handler = useCaseTestHandler(MultiplyCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should multiply by one', () async {
      final input = {'x': 42, 'y': 1};
      final handler = useCaseTestHandler(MultiplyCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });
  });
}
