import 'dart:convert';
import 'package:test/test.dart';
import 'package:shelf/shelf.dart';
import 'package:modular_api/src/core/schema/field.dart';
import 'package:modular_api/src/core/logger/logger.dart';
import 'package:modular_api/src/core/logger/logging_middleware.dart';
import 'package:modular_api/src/core/usecase/usecase.dart';
import 'package:modular_api/src/core/usecase/usecase_http_handler.dart';
import 'package:modular_api/src/core/usecase/use_case_exception.dart';

class PingInput extends Input {
  final String payload;
  PingInput({required this.payload});

  factory PingInput.fromJson(Map<String, dynamic> json) =>
      PingInput(payload: json['payload'] as String);

  @override
  Map<String, dynamic> toJson() => {'payload': payload};

  @override
  List<SchemaField> get schemaFields =>
      [SchemaField.string('payload', example: 'hello')];

  static PingInput get example => PingInput(payload: 'hello');
}

class PingOutput extends Output {
  final String echo;
  PingOutput({required this.echo});

  @override
  int get statusCode => 200;

  @override
  Map<String, dynamic> toJson() => {'echo': echo};
}

class FailingUseCase implements UseCase<PingInput, PingOutput> {
  @override
  final PingInput input;
  @override
  ModularLogger? logger;
  FailingUseCase(this.input);

  factory FailingUseCase.fromJson(Map<String, dynamic> json) =>
      FailingUseCase(PingInput.fromJson(json));

  @override
  String? validate() => null;

  @override
  Future<PingOutput> execute() async {
    throw UseCaseException(statusCode: 422, message: 'business rule violated');
  }
}

class CrashingUseCase implements UseCase<PingInput, PingOutput> {
  @override
  final PingInput input;
  @override
  ModularLogger? logger;
  CrashingUseCase(this.input);

  factory CrashingUseCase.fromJson(Map<String, dynamic> json) =>
      CrashingUseCase(PingInput.fromJson(json));

  @override
  String? validate() => null;

  @override
  Future<PingOutput> execute() async {
    throw StateError('unexpected null');
  }
}

Handler wrapWithLogging(Handler inner, List<String> logLines) {
  final mw = loggingMiddleware(
    logLevel: LogLevel.debug,
    serviceName: 'test-svc',
    sink: CapturingSink(logLines),
  );
  return mw(inner);
}

class CapturingSink implements StringSink {
  final List<String> lines;
  CapturingSink(this.lines);

  @override
  void write(Object? object) => lines.add(object.toString());
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      lines.add(objects.join(separator));
  @override
  void writeCharCode(int charCode) => lines.add(String.fromCharCode(charCode));
  @override
  void writeln([Object? object = '']) => lines.add(object.toString());
}

Request postJson(String path, Map<String, dynamic> body, {String? traceId}) {
  final headers = <String, String>{
    'content-type': 'application/json',
    if (traceId != null) 'X-Request-ID': traceId,
  };
  return Request('POST', Uri.parse('http://localhost$path'),
      body: jsonEncode(body), headers: headers);
}

void main() {
  group('useCaseHttpHandler scoped-logger integration (issue #7)', () {
    test('logs UseCaseException through scoped logger with trace_id', () async {
      final logLines = <String>[];
      final handler = wrapWithLogging(
        useCaseHttpHandler(FailingUseCase.fromJson,
            inputExample: PingInput.example),
        logLines,
      );
      const traceId = 'trace-uce-dart-001';
      final response =
          await handler(postJson('/test', {'payload': 'hi'}, traceId: traceId));

      expect(response.statusCode, equals(422));

      final errorLogs = logLines
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .where((e) =>
              e['level'] == 'error' &&
              (e['msg'] as String).contains('UseCaseException'))
          .toList();

      expect(errorLogs, isNotEmpty,
          reason: 'expected error log from scoped logger');
      expect(errorLogs.first['trace_id'], equals(traceId));
    });

    test('logs unexpected errors through scoped logger with trace_id',
        () async {
      final logLines = <String>[];
      final handler = wrapWithLogging(
        useCaseHttpHandler(CrashingUseCase.fromJson,
            inputExample: PingInput.example),
        logLines,
      );
      const traceId = 'trace-crash-dart-002';
      final response =
          await handler(postJson('/test', {'payload': 'hi'}, traceId: traceId));

      expect(response.statusCode, equals(500));

      final errorLogs = logLines
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .where((e) =>
              e['level'] == 'error' &&
              (e['msg'] as String).contains('Unexpected error'))
          .toList();

      expect(errorLogs, isNotEmpty,
          reason: 'expected error log from scoped logger');
      expect(errorLogs.first['trace_id'], equals(traceId));
    });

    test('does not throw when logger is unavailable', () async {
      final handler = useCaseHttpHandler(FailingUseCase.fromJson,
          inputExample: PingInput.example);

      final response = await handler(postJson('/test', {'payload': 'hi'}));

      expect(response.statusCode, equals(422));
      final body = jsonDecode(await response.readAsString());
      expect(body['message'], equals('business rule violated'));
    });
  });
}
