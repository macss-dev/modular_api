@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as sdk;
import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:http/http.dart' as http;
import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';

/// Gate G5 — a real OpenTelemetry Collector accepts the spans our instrumentation produces.
///
/// **This test validates wiring, not an encoder.** ADR-0005 A3 gave the wire format away: the
/// OTel SDK serialises OTLP and we never touch it. What can still be wrong is everything
/// around that — whether our host span is well-formed, whether ambient context makes a nested
/// span a real child, whether the flush at shutdown actually happens. A genuine Collector
/// parsing our payload and re-emitting it is the only evidence that reaches all of it at once.
///
/// **Dart only**, per D16: the same OTLP export path in TypeScript and Python is the official
/// SDKs' own, tested upstream far more thoroughly than we could. What is ours — span shape and
/// parent-child structure — is compared across the three languages in Stage 11 instead.
///
/// Start the Collector with `docker compose up -d collector` in `code/infra/docker`. When it is
/// not reachable these tests **skip** rather than fail: a suite that reports failures for absent
/// infrastructure trains the reader to ignore a red result, which is exactly how a genuine
/// regression hides. They are skipped by default (see `dart_test.yaml`) and run with
/// `dart test --run-skipped test/tracing/collector_integration_test.dart`.
///
/// **The three-package hierarchy is not asserted here**, though the runbook first planned it.
/// Core cannot dev-depend on `modular_api_rest_client` and `modular_api_postgres` by path
/// without making itself unpublishable, and simulating their spans with hand-built ones would
/// prove only that the SDK nests spans. That assertion belongs to Stage 14, where `socia`
/// exercises all three packages in a real deployment.
void main() {
  /// Where the Collector's `file` exporter writes, as seen from this test's working directory.
  final spansFile = File('../../infra/docker/collector/output/spans.jsonl');
  final collectorEndpoint =
      Platform.environment['MODULAR_API_OTLP_ENDPOINT'] ?? 'http://127.0.0.1:4318';

  String? unavailableReason;

  setUpAll(() async {
    // Probed once per suite, so an unavailable Collector costs one timeout rather than one per
    // test. An empty OTLP payload is the cheapest possible liveness check that still proves the
    // traces pipeline is configured — a 404 would mean a Collector with no otlp receiver.
    try {
      final response = await http
          .post(
            Uri.parse('$collectorEndpoint/v1/traces'),
            headers: {'content-type': 'application/json'},
            body: '{"resourceSpans":[]}',
          )
          .timeout(const Duration(seconds: 3));
      if (response.statusCode != 200) {
        unavailableReason =
            'the OTLP endpoint answered ${response.statusCode} rather than 200';
      }
    } catch (error) {
      unavailableReason = 'the Collector is not reachable at $collectorEndpoint ($error)';
    }

    if (unavailableReason == null && !spansFile.parent.existsSync()) {
      unavailableReason =
          'the Collector is running but ${spansFile.parent.path} does not exist, so its file '
          'exporter is not bind-mounted where this test can read it';
    }
  });

  /// Reports the test as skipped and tells the body to stop.
  ///
  /// `setUp` cannot do this: `markTestSkipped` only affects the report, it does not prevent the
  /// body from executing, so each test must return explicitly.
  bool skipUnlessReachable() {
    if (unavailableReason == null) return false;
    markTestSkipped(
      '$unavailableReason. Start it with `docker compose up -d collector` in '
      'code/infra/docker, or point MODULAR_API_OTLP_ENDPOINT at a live Collector.',
    );
    return true;
  }

  /// Everything the Collector has written, one OTLP-JSON object per line.
  ///
  /// The file is append-only across container lifetimes, so tests filter by service name rather
  /// than truncating it — truncating a bind-mounted file the container holds open does not
  /// reliably reset the writer's offset.
  List<Map<String, Object?>> receivedPayloads() {
    if (!spansFile.existsSync()) return const [];
    return spansFile
        .readAsLinesSync()
        .where((line) => line.trim().isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, Object?>)
        .toList();
  }

  /// Flattens the OTLP envelope down to the spans belonging to [serviceName].
  ///
  /// The nesting — resourceSpans → scopeSpans → spans — is OTLP's, not ours, and walking it here
  /// is what makes the assertions read as span facts instead of protocol facts.
  List<Map<String, Object?>> spansForService(String serviceName) {
    final result = <Map<String, Object?>>[];

    for (final payload in receivedPayloads()) {
      for (final resourceSpan
          in (payload['resourceSpans'] as List<Object?>? ?? const [])) {
        final resource = (resourceSpan as Map<String, Object?>)['resource']
            as Map<String, Object?>?;
        final attributes = resource?['attributes'] as List<Object?>? ?? const [];

        final matches = attributes.any((attribute) {
          final entry = attribute as Map<String, Object?>;
          if (entry['key'] != 'service.name') return false;
          final value = entry['value'] as Map<String, Object?>?;
          return value?['stringValue'] == serviceName;
        });
        if (!matches) continue;

        for (final scopeSpan in (resourceSpan['scopeSpans'] as List<Object?>? ?? const [])) {
          for (final span
              in ((scopeSpan as Map<String, Object?>)['spans'] as List<Object?>? ??
                  const [])) {
            result.add(span as Map<String, Object?>);
          }
        }
      }
    }

    return result;
  }

  /// Runs one traced request and waits for the Collector to have written its spans.
  ///
  /// Returns the spans that arrived for [serviceName]. Polls rather than sleeping a fixed
  /// interval: a fixed sleep is either flaky or slow, and there is no callback to await — the
  /// evidence is a file another process writes.
  Future<List<Map<String, Object?>>> traceOneRequest({
    required String serviceName,
    required Future<void> Function(int port) request,
    bool closeServerToFlush = true,
  }) async {
    // A fresh SDK per test, because the service name is what separates this test's spans from
    // every other run's in an append-only file. `initialize` throws if called twice, hence the
    // reset.
    await sdk.OTel.reset();
    await sdk.OTel.initialize(
      serviceName: serviceName,
      endpoint: '$collectorEndpoint/v1/traces',
      // The processor is supplied explicitly rather than left to the default, which exports over
      // gRPC. The Collector here speaks OTLP/HTTP, and being explicit is also what an application
      // has to do — A2 makes this choice the application's, so the test makes it the way one would.
      spanProcessor: sdk.SimpleSpanProcessor(
        sdk.OtlpHttpSpanExporter(
          sdk.OtlpHttpExporterConfig(endpoint: '$collectorEndpoint/v1/traces'),
        ),
      ),
      // Metrics and logs would open their own gRPC exporters against an endpoint that only serves
      // traces here, and their retries are noise in this test's output.
      enableMetrics: false,
      enableLogs: false,
    );

    final api = ModularApi(
      basePath: '/api',
      title: serviceName,
      tracing: TracingOptions(
        tracerProvider: sdk.OTel.tracerProvider(),
        // D8 as revised: the framework owns the moment, the application owns the resource. This
        // is exactly what a Cloud Run container has to do before it is killed, which is why the
        // scale-to-zero case is worth asserting rather than assuming.
        onShutdown: () async => sdk.OTel.tracerProvider().shutdown(),
      ),
    );
    api.module('cuenta', (m) {
      m.usecase(
        'detalle',
        _DetalleUseCase.fromJson,
        inputExample: _DetalleInput(dni: '1'),
        outputExample: _DetalleOutput(echo: '1'),
      );
    });

    final server = await api.serve(port: 0);
    try {
      await request(server.port);
    } finally {
      if (closeServerToFlush) {
        await server.close();
      } else {
        await server.close(force: true);
      }
    }

    for (var attempt = 0; attempt < 40; attempt++) {
      final spans = spansForService(serviceName);
      if (spans.isNotEmpty) return spans;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    return spansForService(serviceName);
  }

  Future<void> postDetalle(int port) async {
    await http.post(
      Uri.parse('http://localhost:$port/api/cuenta/detalle'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'dni': '12345678'}),
    );
  }

  test('the Collector accepts spans exported through the OTel SDK', () async {
    if (skipUnlessReachable()) return;

    final spans = await traceOneRequest(
      serviceName: 'g5-accepts-${DateTime.now().microsecondsSinceEpoch}',
      request: postDetalle,
    );

    // A 200 from the receiver only means it read the bytes. This means it parsed them, ran them
    // through a pipeline and wrote them out — the difference between "accepted" and "understood".
    expect(spans, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('the exported spans carry our name, kind and attributes', () async {
    if (skipUnlessReachable()) return;

    final spans = await traceOneRequest(
      serviceName: 'g5-shape-${DateTime.now().microsecondsSinceEpoch}',
      request: postDetalle,
    );
    final server = spans.firstWhere(
      (span) => span['name'] == 'POST /api/cuenta/detalle',
      orElse: () => throw StateError('no server span in ${spans.map((s) => s['name'])}'),
    );

    // SPAN_KIND_SERVER is 2 in OTLP's enum. Asserted as the number the wire actually carries,
    // because that is what a backend reads — not the SDK enum we set it from.
    expect(server['kind'], equals(2));

    final attributes = {
      for (final attribute in server['attributes'] as List<Object?>)
        (attribute as Map<String, Object?>)['key'] as String:
            (attribute['value'] as Map<String, Object?>).values.first,
    };

    expect(attributes['http.request.method'], equals('POST'));
    expect(attributes['url.path'], equals('/api/cuenta/detalle'));
    expect(attributes['http.response.status_code'], anyOf(equals(200), equals('200')));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a nested span survives the round trip as a real child', () async {
    if (skipUnlessReachable()) return;

    // The property that everything downstream rests on. A span carrying the right trace id with
    // the wrong parent looks correct in the id column and is broken in the waterfall — the exact
    // failure Stage 5 shipped and had to fix. Here it is checked against the bytes a backend
    // would receive, rather than against an in-memory exporter.
    final spans = await traceOneRequest(
      serviceName: 'g5-nesting-${DateTime.now().microsecondsSinceEpoch}',
      request: postDetalle,
    );

    final server = spans.firstWhere((span) => span['name'] == 'POST /api/cuenta/detalle');
    final nested = spans.firstWhere((span) => span['name'] == 'upstream impulsa');

    expect(nested['traceId'], equals(server['traceId']));
    expect(nested['parentSpanId'], equals(server['spanId']));
    expect(nested['parentSpanId'], isNot(equals('0000000000000000')));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('provider shutdown flushes pending spans to the Collector (D8)', () async {
    if (skipUnlessReachable()) return;

    // The scale-to-zero case. On Cloud Run the window between the last request and the container
    // dying is the only chance to flush, and D8 as revised makes that window the framework's to
    // offer and the application's to use. If closing the server did not invoke onShutdown, this
    // test is the one that would go quiet.
    final spans = await traceOneRequest(
      serviceName: 'g5-flush-${DateTime.now().microsecondsSinceEpoch}',
      request: postDetalle,
    );

    expect(spans.map((span) => span['name']), contains('POST /api/cuenta/detalle'));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('the suite skips with an actionable message when the Collector is absent', () {
    // Not a tautology: it asserts the *shape* of the skip path, which is what keeps an absent
    // fixture from reading as a broken build. Either the reason is null and the suite ran for
    // real, or the reason says where to look and how to fix it.
    expect(
      unavailableReason,
      anyOf(
        isNull,
        allOf(contains('Collector'), isNot(isEmpty)),
      ),
    );
  });
}

class _DetalleInput extends Input {
  _DetalleInput({required this.dni});

  factory _DetalleInput.fromJson(Map<String, dynamic> json) =>
      _DetalleInput(dni: json['dni'] as String? ?? '');

  final String dni;

  @override
  Map<String, dynamic> toJson() => {'dni': dni};

  @override
  Map<String, dynamic> toSchema() => {
        'type': 'object',
        'properties': {
          'dni': {'type': 'string'},
        },
        'required': ['dni'],
      };
}

class _DetalleOutput extends Output {
  _DetalleOutput({required this.echo});

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

/// Stands in for `socia`'s `get-cuenta-detalle`, which is an HTTP proxy with no database work.
///
/// The nested span is created with the plain OTel API and no argument threaded in, which is the
/// point: the handler reaches the server span through ambient context alone. That is the same
/// mechanism `modular_api_rest_client` uses to parent its client span, so proving it here proves
/// it for the satellite without core depending on the satellite.
class _DetalleUseCase implements UseCase<_DetalleInput, _DetalleOutput> {
  _DetalleUseCase({required this.input});

  static _DetalleUseCase fromJson(Map<String, dynamic> json) =>
      _DetalleUseCase(input: _DetalleInput.fromJson(json));

  @override
  final _DetalleInput input;

  @override
  ModularLogger? logger;

  @override
  String? validate() => null;

  @override
  Future<_DetalleOutput> execute() async {
    final span = OTelAPI.tracerProvider()
        .getTracer('collector-integration-test')
        .startSpan('upstream impulsa', kind: SpanKind.client);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    span.end();

    return _DetalleOutput(echo: input.dni);
  }
}
