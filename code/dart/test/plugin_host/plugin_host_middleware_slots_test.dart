import 'dart:convert';
import 'dart:io';

import 'package:modular_api/modular_api.dart';
import 'package:modular_api/src/core/logger/logging_middleware.dart';
import 'package:test/test.dart';

void main() {
  group('Plugin middleware slots', () {
    test('orders middleware by slot, order, and setup order without bypassing the use case lifecycle', () async {
      final events = <String>[];
      final api = ModularApi(basePath: '/api', title: 'Stage 4 API')
        ..plugin(MiddlewarePlugin(id: 'acme.first', events: events, definitions: [
          recordingMiddlewareDefinition('preHandler:first', 'preHandler', 5, events),
        ]))
        ..plugin(MiddlewarePlugin(id: 'acme.second', events: events, definitions: [
          recordingMiddlewareDefinition('preHandler:second', 'preHandler', 5, events),
        ]))
        ..plugin(MiddlewarePlugin(id: 'acme.low', events: events, definitions: [
          loggingProbeMiddlewareDefinition(events),
          recordingMiddlewareDefinition('preHandler:low', 'preHandler', 1, events),
          recordingMiddlewareDefinition('postHandler:low', 'postHandler', 0, events),
        ]))
        ..use(recordingCustomMiddleware(events, 'custom'));

      api.module('demo', (m) {
        m.usecase(
          'pipeline',
          (json) => Stage4UseCase(input: Stage4Input.fromJson(json), events: events),
          inputExample: Stage4Input(),
          outputExample: Stage4Output(),
        );
      });

      final server = await api.serve(port: 0);
      addTearDown(() => server.close(force: true));

      final client = HttpClient();
      final request = await client.postUrl(Uri.parse('http://127.0.0.1:${server.port}/api/demo/pipeline'));
      request.headers.set('X-Request-ID', 'trace-stage4-order');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'name': 'Ada'}));
      final response = await request.close();

      expect(response.statusCode, 200);
      expect(events, [
        'preRouting:logger',
        'custom',
        'preHandler:low',
        'preHandler:first',
        'preHandler:second',
        'postHandler:low',
        'validate',
        'execute',
      ]);
    });

    test('rejects unknown middleware slots during startup', () async {
      final api = ModularApi(basePath: '/api')
        ..plugin(MiddlewarePlugin(id: 'acme.invalid', events: const [], definitions: [
          recordingMiddlewareDefinition('invalid', 'moonPhase', 0, const []),
        ]));

      await expectLater(
        api.serve(port: 0),
        throwsA(isA<PluginHostError>().having((error) => error.code, 'code', 'PLUGIN_VALIDATION_FAILED')),
      );
    });

    test('passes a full request context to plugin route handlers', () async {
      final api = ModularApi(basePath: '/api')..plugin(ContextRoutePlugin());

      final server = await api.serve(port: 0);
      addTearDown(() => server.close(force: true));

      final client = HttpClient();
      final request = await client.postUrl(Uri.parse('http://127.0.0.1:${server.port}/api/plugin-context/alice?lang=dart'));
      request.headers.set('X-Request-ID', 'trace-stage4-context');
      request.headers.set('X-Stage4', 'present');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'hello': 'world'}));
      final response = await request.close();
      final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, dynamic>;

      expect(response.statusCode, 200);
      expect(body['requestId'], 'trace-stage4-context');
      expect(body['loggerPresent'], true);
      expect(body['method'], 'POST');
      expect(body['path'], '/api/plugin-context/alice');
      expect(body['stageHeader'], 'present');
      expect(body['queryLang'], 'dart');
      expect(body['bodyHello'], 'world');
      expect(body['pathName'], 'alice');
      expect(body['capabilityIds'], contains('acme.capability'));
    });
  });
}

class Stage4Input extends Input {
  final String name;

  Stage4Input({this.name = ''});

  factory Stage4Input.fromJson(Map<String, dynamic> json) {
    return Stage4Input(name: json['name']?.toString() ?? '');
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

class Stage4Output extends Output {
  final String message;

  Stage4Output({this.message = 'ok'});

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

class Stage4UseCase implements UseCase<Stage4Input, Stage4Output> {
  @override
  final Stage4Input input;

  final List<String> events;

  @override
  ModularLogger? logger;

  Stage4UseCase({required this.input, required this.events});

  @override
  String? validate() {
    events.add('validate');
    return null;
  }

  @override
  Future<Stage4Output> execute() async {
    events.add('execute');
    return Stage4Output(message: 'Hello, ${input.name}');
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

  final List<String> events;
  final List<MiddlewareDefinition> definitions;

  MiddlewarePlugin({
    required String id,
    required this.events,
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

class ContextRoutePlugin implements Plugin {
  @override
  final PluginManifest manifest = const PluginManifest(
    id: 'acme.context',
    displayName: 'Context Plugin',
    version: '0.1.0',
    hostApiVersion: '>=0.1.0 <0.2.0',
  );

  @override
  void setup(PluginHost host) {
    host.exposeCapability(
      const Capability(id: 'acme.capability', version: '1.0.0', value: true),
    );

    host.registerRoute(
      PluginRoute(
        id: 'plugin-context',
        method: 'POST',
        path: '/plugin-context/<name>',
        visibility: 'custom',
        handler: (context) => Response.ok(
          jsonEncode({
            'requestId': context.requestId,
            'loggerPresent': context.logger != null,
            'method': context.method,
            'path': context.path,
            'stageHeader': context.headers['x-stage4'],
            'queryLang': context.query['lang'],
            'bodyHello': (context.body as Map<String, dynamic>)['hello'],
            'pathName': context.pathParams['name'],
            'capabilityIds': context.capabilities().keys.toList(),
          }),
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
  }
}

Middleware recordingCustomMiddleware(List<String> events, String label) {
  return (innerHandler) {
    return (request) async {
      events.add(label);
      return innerHandler(request);
    };
  };
}

MiddlewareDefinition loggingProbeMiddlewareDefinition(List<String> events) {
  return MiddlewareDefinition(
    id: 'preRouting.logger',
    slot: 'preRouting',
    order: 0,
    handler: (innerHandler) {
      return (request) async {
        events.add(request.context[loggerContextKey] == null ? 'preRouting:no-logger' : 'preRouting:logger');
        return innerHandler(request);
      };
    },
  );
}

MiddlewareDefinition recordingMiddlewareDefinition(String label, String slot, int order, List<String> events) {
  return MiddlewareDefinition(
    id: label,
    slot: slot,
    order: order,
    handler: (innerHandler) {
      return (request) async {
        events.add(label);
        return innerHandler(request);
      };
    },
  );
}