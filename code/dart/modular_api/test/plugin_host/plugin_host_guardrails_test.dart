import 'dart:convert';

import 'package:modular_api/modular_api.dart';
import 'package:modular_api/src/core/error_response_middleware.dart';
import 'package:modular_api/src/core/logger/logging_middleware.dart';
import 'package:modular_api/src/core/usecase/usecase_http_handler.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

void main() {
  group('Plugin middleware guardrails', () {
    test('annotates the completed request log when plugin middleware short-circuits before the core handler', () async {
      final events = <String>[];
      final logOutput = StringBuffer();
      final handler = buildGuardrailHandler(
        plugins: [
          MiddlewarePlugin(
            id: 'acme.guard',
            definitions: [
              MiddlewareDefinition(
                id: 'auth',
                slot: 'preHandler',
                order: 0,
                handler: (nextHandler) {
                  return (request) async => Response(
                        401,
                        headers: {'content-type': 'application/json'},
                        body: jsonEncode({'error': 'blocked by plugin'}),
                      );
                },
              ),
            ],
          ),
        ],
        events: events,
        logOutput: logOutput,
      );

      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/demo/pipeline'),
          headers: {'X-Request-ID': 'trace-dart-short-circuit'},
          body: jsonEncode({'name': 'Ada'}),
        ),
      );

      expect(response.statusCode, 401);
      expect(jsonDecode(await response.readAsString()), {'error': 'blocked by plugin'});
      expect(events, isEmpty);

      final lines = logOutput.toString().trim().split('\n');
      final completedLog = jsonDecode(lines.last) as Map<String, dynamic>;
      expect(completedLog['msg'], 'request completed');
      expect(completedLog['trace_id'], 'trace-dart-short-circuit');
      expect(completedLog['short_circuit'], isTrue);
      expect(completedLog['short_circuit_plugin_id'], 'acme.guard');
      expect(completedLog['short_circuit_middleware_id'], 'acme.guard.auth');
      expect(completedLog['short_circuit_slot'], 'preHandler');
    });

    test('returns a normalized 500 JSON response when plugin middleware throws outside the core handler', () async {
      final events = <String>[];
      final logOutput = StringBuffer();
      final handler = buildGuardrailHandler(
        plugins: [
          MiddlewarePlugin(
            id: 'acme.guard',
            definitions: [
              MiddlewareDefinition(
                id: 'boom',
                slot: 'preHandler',
                order: 0,
                handler: (nextHandler) {
                  return (request) async => throw StateError('boom');
                },
              ),
            ],
          ),
        ],
        events: events,
        logOutput: logOutput,
      );

      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/demo/pipeline'),
          headers: {'X-Request-ID': 'trace-dart-error-guardrail'},
          body: jsonEncode({'name': 'Ada'}),
        ),
      );

      expect(response.statusCode, 500);
      expect(jsonDecode(await response.readAsString()), {'error': 'Internal server error'});
      expect(events, isEmpty);

      final lines = logOutput.toString().trim().split('\n');
      final parsedLogs = lines.map((line) => jsonDecode(line) as Map<String, dynamic>).toList();
      final errorLog = parsedLogs.firstWhere((line) => line['msg'] == 'Unhandled error in request pipeline');
      expect(errorLog['trace_id'], 'trace-dart-error-guardrail');
      expect(errorLog['level'], 'error');
      expect(errorLog['fields'], {'error': 'Bad state: boom', 'status': 500});

      final completedLog = parsedLogs.last;
      expect(completedLog['msg'], 'request completed');
      expect(completedLog['status'], 500);
      expect(completedLog.containsKey('short_circuit'), isFalse);
    });
  });
}

Handler buildGuardrailHandler({
  required List<Plugin> plugins,
  required List<String> events,
  required StringBuffer logOutput,
}) {
  final host = RuntimePluginHost(
    basePath: '/api',
    title: 'Guardrail Test API',
    version: '0.1.0',
  );

  for (final plugin in plugins) {
    host.beginPluginSetup(plugin.manifest.id);
    plugin.setup(host);
    host.endPluginSetup();
  }

  host.freeze();
  host.assertValid();

  final router = Router()
    ..post(
      '/api/demo/pipeline',
      useCaseHttpHandler(
        (json) => GuardrailUseCase(
          input: GuardrailInput.fromJson(json),
          events: events,
        ),
        inputExample: GuardrailInput(),
      ),
    );

  var pipeline = const Pipeline().addMiddleware(
    loggingMiddleware(
      logLevel: LogLevel.debug,
      serviceName: 'guardrail-test',
      sink: logOutput,
    ),
  );
  pipeline = pipeline.addMiddleware(errorResponseMiddleware());

  for (final middleware in host.middlewaresForSlot('preRouting')) {
    pipeline = pipeline.addMiddleware(middleware.handler);
  }
  for (final middleware in host.middlewaresForSlot('preHandler')) {
    pipeline = pipeline.addMiddleware(middleware.handler);
  }
  for (final middleware in host.middlewaresForSlot('postHandler')) {
    pipeline = pipeline.addMiddleware(middleware.handler);
  }

  return pipeline.addHandler(router.call);
}

class GuardrailInput extends Input {
  final String name;

  GuardrailInput({this.name = ''});

  factory GuardrailInput.fromJson(Map<String, dynamic> json) {
    return GuardrailInput(name: json['name']?.toString() ?? '');
  }

  @override
  Map<String, dynamic> toJson() => {'name': name};

  @override
  Map<String, dynamic> toSchema() => {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
        },
        'required': ['name'],
      };
}

class GuardrailOutput extends Output {
  final String message;

  GuardrailOutput({this.message = 'ok'});

  @override
  int get statusCode => 200;

  @override
  Map<String, dynamic> toJson() => {'message': message};

  @override
  Map<String, dynamic> toSchema() => {
        'type': 'object',
        'properties': {
          'message': {'type': 'string'},
        },
        'required': ['message'],
      };
}

class GuardrailUseCase implements UseCase<GuardrailInput, GuardrailOutput> {
  @override
  final GuardrailInput input;

  final List<String> events;

  @override
  ModularLogger? logger;

  GuardrailUseCase({required this.input, required this.events});

  @override
  String? validate() {
    events.add('validate');
    return null;
  }

  @override
  Future<GuardrailOutput> execute() async {
    events.add('execute');
    return GuardrailOutput(message: 'Hello, ${input.name}');
  }
}

class MiddlewareDefinition {
  final String id;
  final String slot;
  final int order;
  final Middleware handler;

  const MiddlewareDefinition({
    required this.id,
    required this.slot,
    required this.order,
    required this.handler,
  });
}

class MiddlewarePlugin implements Plugin {
  @override
  final PluginManifest manifest;

  final List<MiddlewareDefinition> definitions;

  MiddlewarePlugin({
    required String id,
    required this.definitions,
  }) : manifest = PluginManifest(
          id: id,
          displayName: 'Middleware Plugin',
          version: '0.1.0',
          hostApiVersion: '>=0.1.0 <0.2.0',
        );

  @override
  void setup(PluginHost host) {
    for (final definition in definitions) {
      host.registerMiddleware(
        PluginMiddleware(
          id: '${manifest.id}.${definition.id}',
          slot: definition.slot,
          order: definition.order,
          handler: definition.handler,
        ),
      );
    }
  }
}