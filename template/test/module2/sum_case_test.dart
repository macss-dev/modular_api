import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';
import '../../lib/modules/module2/usecases/usecase_1.dart';

void main() {
  group('SumCase UseCase', () {
    test('should sum two positive numbers', () async {
      final input = {'a': 10, 'b': 5};
      final handler = useCaseTestHandler(SumCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should sum zero values', () async {
      final input = {'a': 0, 'b': 0};
      final handler = useCaseTestHandler(SumCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should sum decimal numbers', () async {
      final input = {'a': 3.5, 'b': 2.7};
      final handler = useCaseTestHandler(SumCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should sum large numbers', () async {
      final input = {'a': 1000000, 'b': 2000000};
      final handler = useCaseTestHandler(SumCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });

    test('should fail with negative numbers', () async {
      final input = {'a': -5, 'b': 10};
      final handler = useCaseTestHandler(SumCase.fromJson);

      final result = await handler(input);

      expect(result, isFalse);
    });

    test('should fail when both numbers are negative', () async {
      final input = {'a': -10, 'b': -5};
      final handler = useCaseTestHandler(SumCase.fromJson);

      final result = await handler(input);

      expect(result, isFalse);
    });

    test('should handle string numbers', () async {
      final input = {'a': '15', 'b': '25'};
      final handler = useCaseTestHandler(SumCase.fromJson);

      final result = await handler(input);

      expect(result, isTrue);
    });
  });
}
