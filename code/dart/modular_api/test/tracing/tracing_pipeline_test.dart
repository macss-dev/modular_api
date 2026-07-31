import 'dart:convert';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as sdk;
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:http/http.dart' as http;
import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';

/// Integration tests for tracing as the host actually wires it.
///
/// The middleware's own behaviour is covered in `tracing_middleware_test.dart`.
/// What is tested here is the wiring: that `serve()` installs it in the right place,
/// that absent options install nothing at all, and that operational routes stay out
/// of the trace store.
///
/// These run a real server on a real port, because the thing under test is the
/// pipeline `serve()` builds — asserting it by inspecting a `Pipeline` object would
/// be testing a reconstruction of the code rather than the code.
void main() {
  late TestHarness harness;
  late InMemorySpanExporter spans;

  setUpAll(() async {
    harness = await maybeInitializeOtelForTest(serviceName: 'modular_api-test');
    spans = harness.spans;
  });

  setUp(() => harness.clear());

  TracingOptions tracingOptions() =>
      TracingOptions(tracerProvider: sdk.OTel.tracerProvider());

  ModularApi apiWith({TracingOptions? tracing}) {
    final api = ModularApi(
      basePath: '/api',
      title: 'modular_api-test',
      tracing: tracing,
    );
    api.module('cuenta', (m) {
      m.usecase(
        'ping',
        PingUseCase.fromJson,
        inputExample: PingInput(value: 'ping'),
        outputExample: PingOutput(echo: 'ping'),
      );
      m.usecase(
        'boom',
        BoomUseCase.fromJson,
        inputExample: PingInput(value: 'ping'),
        outputExample: PingOutput(echo: 'ping'),
      );
    });
    return api;
  }

  Future<http.Response> post(int port, String path) => http.post(
        Uri.parse('http://localhost:$port$path'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'value': 'ping'}),
      );

  group('with TracingOptions', () {
    late HttpServer server;

    tearDown(() async => server.close(force: true));

    test('a request through the real pipeline produces a server span', () async {
      server = await apiWith(tracing: tracingOptions()).serve(port: 0);

      await post(server.port, '/api/cuenta/ping');

      expect(spans.spanNames, contains('POST /api/cuenta/ping'));
    });

    test('the span carries the route and a 200 status', () async {
      server = await apiWith(tracing: tracingOptions()).serve(port: 0);

      await post(server.port, '/api/cuenta/ping');

      final span = spans.findSpanByName('POST /api/cuenta/ping')!;
      expect(span.attributes.getString('url.path'), equals('/api/cuenta/ping'));
      expect(span.attributes.getInt('http.response.status_code'), equals(200));
    });

    test('operational routes produce no span', () async {
      // Health, docs, openapi and metrics are noise in a trace store. The host
      // derives the exclusion list from operationalRoutePaths rather than hardcoding
      // it, so this also guards against that list drifting.
      server = await apiWith(tracing: tracingOptions()).serve(port: 0);

      await http.get(Uri.parse('http://localhost:${server.port}/api/health'));
      await http.get(Uri.parse('http://localhost:${server.port}/api/openapi.json'));

      expect(spans.spans, isEmpty);
    });

    test('a failing use case still produces an ended span', () async {
      server = await apiWith(tracing: tracingOptions()).serve(port: 0);

      await post(server.port, '/api/cuenta/boom');

      final span = spans.findSpanByName('POST /api/cuenta/boom');
      expect(span, isNotNull);
      expect(span!.endTime, isNotNull);
    });

    test('the span is a child of an incoming traceparent', () async {
      // End to end, through a real socket: the header arrives, propagation resolves
      // it, and the span attaches. This is the path Cloud Run exercises.
      server = await apiWith(tracing: tracingOptions()).serve(port: 0);
      const traceId = '4bf92f3577b34da6a3ce929d0e0e4736';

      await http.post(
        Uri.parse('http://localhost:${server.port}/api/cuenta/ping'),
        headers: {
          'content-type': 'application/json',
          'traceparent': '00-$traceId-00f067aa0ba902b7-01',
        },
        body: jsonEncode({'value': 'ping'}),
      );

      final span = spans.findSpanByName('POST /api/cuenta/ping')!;
      expect(span.spanContext.traceId.hexString, equals(traceId));
      expect(
        span.spanContext.parentSpanId?.hexString,
        equals('00f067aa0ba902b7'),
      );
    });
  });

  group('without TracingOptions (gate G3)', () {
    late HttpServer server;

    tearDown(() async => server.close(force: true));

    test('no span is produced at all', () async {
      // The structural half of G3: off means nothing installed, not "installed and
      // idle". Even a no-op tracer would have produced span objects here.
      server = await apiWith().serve(port: 0);

      final response = await post(server.port, '/api/cuenta/ping');

      expect(response.statusCode, equals(200));
      expect(spans.spans, isEmpty);
    });

    test('the API still serves normally', () async {
      // Invariant 3: a REST-only API is valid with or without optional plugins.
      server = await apiWith().serve(port: 0);

      final response = await post(server.port, '/api/cuenta/ping');

      expect(response.statusCode, equals(200));
      expect(jsonDecode(response.body), equals({'echo': 'ping'}));
      // The home-grown correlation header is untouched by tracing being absent.
      expect(response.headers['x-request-id'], isNotNull);
    });
  });
}

// ─── Fixtures ──────────────────────────────────────────────────────

class PingInput extends Input {
  PingInput({required this.value});

  factory PingInput.fromJson(Map<String, dynamic> json) =>
      PingInput(value: json['value'] as String? ?? '');

  final String value;

  @override
  Map<String, dynamic> toJson() => {'value': value};

  @override
  Map<String, dynamic> toSchema() => {
        'type': 'object',
        'properties': {
          'value': {'type': 'string'},
        },
        'required': ['value'],
      };
}

class PingOutput extends Output {
  PingOutput({required this.echo});

  final String echo;

  @override
  int get statusCode => 200;

  @override
  Map<String, dynamic> toJson() => {'echo': echo};

  @override
  Map<String, dynamic> toSchema() => {
        'type': 'object',
        'properties': {
          'echo': {'type': 'string'},
        },
        'required': ['echo'],
      };
}

class PingUseCase implements UseCase<PingInput, PingOutput> {
  PingUseCase({required this.input});

  static PingUseCase fromJson(Map<String, dynamic> json) =>
      PingUseCase(input: PingInput.fromJson(json));

  @override
  final PingInput input;

  @override
  ModularLogger? logger;

  @override
  String? validate() => null;

  @override
  Future<PingOutput> execute() async => PingOutput(echo: input.value);
}

class BoomUseCase implements UseCase<PingInput, PingOutput> {
  BoomUseCase({required this.input});

  static BoomUseCase fromJson(Map<String, dynamic> json) =>
      BoomUseCase(input: PingInput.fromJson(json));

  @override
  final PingInput input;

  @override
  ModularLogger? logger;

  @override
  String? validate() => null;

  @override
  Future<PingOutput> execute() async => throw StateError('boom');
}
