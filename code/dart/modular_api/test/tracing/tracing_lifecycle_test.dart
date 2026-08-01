import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as sdk;
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:http/http.dart' as http;
import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';

/// Tests for tracing's configuration and shutdown behaviour.
///
/// **There is deliberately no tracing plugin**, and this file is where that outcome is
/// pinned. Every responsibility ADR-0005 decision 4 gave one was reassigned by a later,
/// better-evidenced decision:
///
/// - **A2** moved the sampler, span processor and exporter to the application.
/// - **Decision 4 itself** made the span host-owned, so no middleware is registered.
/// - **D8 as revised** turned provider shutdown into a callback the application supplies,
///   because the OpenTelemetry API exposes no shutdown on the provider in TypeScript or
///   Python and the provider belongs to the application anyway.
///
/// What was left was a plugin whose `setup()` did nothing and whose only act was to
/// forward one callback. That is indirection with no reader benefit, so the host reads
/// `TracingOptions` directly and invokes the callback in its existing shutdown path.
///
/// Two decisions are pinned so they cannot be undone by habit:
///
/// - **D14** — no dropped-span counter. OpenTelemetry standardises that signal as
///   `otel.sdk.processor.span.processed` with `error.type = queue_full`, and the obligation
///   sits on the SDK's batching processor.
/// - **D8 as revised** — the framework never shuts down or flushes a provider it did not
///   create. It offers the timing; the application decides what that means.
void main() {
  late TestHarness harness;

  setUpAll(() async {
    harness = await maybeInitializeOtelForTest(serviceName: 'modular_api-test');
  });

  setUp(() => harness.clear());

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
    });
    return api;
  }

  TracingOptions options({
    Future<void> Function()? onShutdown,
    String? instrumentationName,
  }) =>
      TracingOptions(
        tracerProvider: sdk.OTel.tracerProvider(),
        onShutdown: onShutdown,
        instrumentationName: instrumentationName ?? 'modular_api',
      );

  group('shutdown timing (D8 as revised)', () {
    test('onShutdown runs when the server closes', () async {
      // On Cloud Run this is the only window before the container dies. The framework
      // supplies the moment; the application supplies the action.
      var called = 0;

      final api = apiWith(tracing: options(onShutdown: () async => called++));
      final server = await api.serve(port: 0);
      await server.close(force: true);

      expect(called, equals(1));
    });

    test('a missing onShutdown is not an error', () async {
      final api = apiWith(tracing: options());
      final server = await api.serve(port: 0);

      await expectLater(server.close(force: true), completes);
    });

    test('an onShutdown that throws does not prevent the server closing', () async {
      // A failing flush must not turn a clean shutdown into a hang or a crash. Losing
      // telemetry is bad; failing to stop is worse.
      final api = apiWith(
        tracing: options(onShutdown: () async => throw StateError('flush failed')),
      );
      final server = await api.serve(port: 0);

      await expectLater(server.close(force: true), completes);
    });

    test('the framework does not shut down the provider itself', () async {
      // D8 as revised. Dart's API happens to expose shutdown() on the provider, and
      // TypeScript's and Python's do not — so using it here would make an observable
      // behaviour differ by language (G6). It is also a resource the application created
      // and may still be using elsewhere.
      final api = apiWith(tracing: options());
      final server = await api.serve(port: 0);
      await server.close(force: true);

      // Still usable after the server closed: nothing was torn down behind the
      // application's back.
      final span = sdk.OTel.tracerProvider()
          .getTracer('after-shutdown')
          .startSpan('still-working')
        ..end();

      expect(span.spanContext.isValid, isTrue);
    });
  });

  group('D14 — no dropped-span counter', () {
    test('tracing registers no metrics of its own', () async {
      // OpenTelemetry standardises this signal as otel.sdk.processor.span.processed with
      // error.type = queue_full, and puts the obligation on the SDK's batching processor.
      // A counter of ours would be a non-standard name beside a standard one, so this test
      // exists to stop it being reintroduced by habit.
      final api = ModularApi(
        basePath: '/api',
        title: 'modular_api-test',
        metricsEnabled: true,
        tracing: options(),
      );
      api.module('cuenta', (m) {
        m.usecase(
          'ping',
          PingUseCase.fromJson,
          inputExample: PingInput(value: 'ping'),
          outputExample: PingOutput(echo: 'ping'),
        );
      });

      final server = await api.serve(port: 0);
      try {
        final metrics = await http
            .get(Uri.parse('http://localhost:${server.port}/api/metrics'));

        expect(metrics.body, isNot(contains('spans_dropped')));
        expect(metrics.body, isNot(contains('span')));
      } finally {
        await server.close(force: true);
      }
    });

    test('tracing works with metrics disabled', () async {
      // Tracing must not require the metrics surface, which it would if it owned a counter.
      final api = apiWith(tracing: options());
      final server = await api.serve(port: 0);

      try {
        final response = await http.post(
          Uri.parse('http://localhost:${server.port}/api/cuenta/ping'),
          headers: {'content-type': 'application/json'},
          body: '{"value":"ping"}',
        );

        expect(response.statusCode, equals(200));
        expect(harness.spans.spanNames, contains('POST /api/cuenta/ping'));
      } finally {
        await server.close(force: true);
      }
    });
  });

  group('configuration', () {
    test('the instrumentation name defaults to modular_api', () {
      expect(options().instrumentationName, equals('modular_api'));
    });

    test('the instrumentation name can be overridden', () {
      expect(
        options(instrumentationName: 'socia-api').instrumentationName,
        equals('socia-api'),
      );
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
