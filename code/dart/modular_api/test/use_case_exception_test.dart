import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';

void main() {
  group('UseCaseException', () {
    test('should have correct properties', () {
      final exception = UseCaseException(
        statusCode: 404,
        message: 'User not found',
        errorCode: 'USER_NOT_FOUND',
        details: {'userId': 123},
      );

      expect(exception.statusCode, equals(404));
      expect(exception.message, equals('User not found'));
      expect(exception.errorCode, equals('USER_NOT_FOUND'));
      expect(exception.details, equals({'userId': 123}));
    });

    test('toJson() should include error and message', () {
      final exception = UseCaseException(
        statusCode: 400,
        message: 'Invalid input',
        errorCode: 'VALIDATION_ERROR',
      );

      final json = exception.toJson();

      expect(json['error'], equals('VALIDATION_ERROR'));
      expect(json['message'], equals('Invalid input'));
      expect(json.containsKey('details'), isFalse);
    });

    test('toJson() should include details when provided', () {
      final exception = UseCaseException(
        statusCode: 422,
        message: 'Account inactive',
        errorCode: 'ACCOUNT_INACTIVE',
        details: {'status': 'suspended'},
      );

      final json = exception.toJson();

      expect(json['error'], equals('ACCOUNT_INACTIVE'));
      expect(json['message'], equals('Account inactive'));
      expect(json['details'], equals({'status': 'suspended'}));
    });

    test('toJson() should use "error" as default errorCode', () {
      final exception = UseCaseException(
        statusCode: 500,
        message: 'Internal error',
      );

      final json = exception.toJson();

      expect(json['error'], equals('error'));
      expect(json['message'], equals('Internal error'));
    });

    test('toString() should format correctly with errorCode', () {
      final exception = UseCaseException(
        statusCode: 404,
        message: 'Not found',
        errorCode: 'RESOURCE_NOT_FOUND',
      );

      expect(
        exception.toString(),
        equals('UseCaseException(404): Not found [RESOURCE_NOT_FOUND]'),
      );
    });

    test('toString() should format correctly without errorCode', () {
      final exception = UseCaseException(
        statusCode: 400,
        message: 'Bad request',
      );

      expect(
        exception.toString(),
        equals('UseCaseException(400): Bad request'),
      );
    });

    test('should throw UseCaseException when shouldThrow is true', () async {
      final useCase = ThrowExceptionUseCase(
        ThrowExceptionInput(shouldThrow: true),
      );

      expect(
        () => useCase.execute(),
        throwsA(isA<UseCaseException>()),
      );
    });

    test('should execute successfully when shouldThrow is false', () async {
      final useCase = ThrowExceptionUseCase(
        ThrowExceptionInput(shouldThrow: false),
      );

      final output = await useCase.execute();
      expect(output.success, isTrue);
    });
  });
}

// Test UseCase
class ThrowExceptionInput extends Input {
  final bool shouldThrow;

  ThrowExceptionInput({required this.shouldThrow});

  factory ThrowExceptionInput.fromJson(Map<String, dynamic> json) {
    return ThrowExceptionInput(
      shouldThrow: json['shouldThrow'] as bool? ?? false,
    );
  }

  @override
  Map<String, dynamic> toJson() => {'shouldThrow': shouldThrow};

  @override
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'shouldThrow': {'type': 'boolean'},
      },
    };
  }
}

class ThrowExceptionOutput extends Output {
  final bool success;

  ThrowExceptionOutput({required this.success});

  factory ThrowExceptionOutput.fromJson(Map<String, dynamic> json) {
    return ThrowExceptionOutput(success: json['success'] as bool);
  }

  @override
  Map<String, dynamic> toJson() => {'success': success};

  @override
  Map<String, dynamic> toSchema() {
    return {
      'type': 'object',
      'properties': {
        'success': {'type': 'boolean'},
      },
    };
  }

  @override
  int get statusCode => 200;
}

class ThrowExceptionUseCase
    implements UseCase<ThrowExceptionInput, ThrowExceptionOutput> {
  @override
  final ThrowExceptionInput input;

  @override
  ModularLogger? logger;

  ThrowExceptionUseCase(this.input);

  static ThrowExceptionUseCase fromJson(Map<String, dynamic> json) {
    return ThrowExceptionUseCase(ThrowExceptionInput.fromJson(json));
  }

  @override
  String? validate() => null;

  @override
  Future<ThrowExceptionOutput> execute() async {
    if (input.shouldThrow) {
      throw UseCaseException(
        statusCode: 404,
        message: 'Resource not found',
        errorCode: 'NOT_FOUND',
      );
    }

    return ThrowExceptionOutput(success: true);
  }
}
