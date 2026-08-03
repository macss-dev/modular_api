import 'dart:convert';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as sdk;
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:modular_api_rest_client/modular_api_rest_client.dart';
import 'package:test/test.dart';

/// Tests for the outbound client span and header propagation.
///
/// **This is the stage that satisfies G7 for `socia`.** Its
/// `POST /api/cuenta/get-cuenta-detalle` performs no database work at all — it is an HTTP
/// proxy to an upstream `impulsa` service (runbook D17). The client span is what will show
/// whether those 8–20 second bursts are spent in the outbound call or before it, which is
/// the whole diagnostic the tracing work exists to produce.
///
/// Two properties are asserted that matter more than the span itself:
///
/// - **Zero configuration.** Nothing is threaded into `ServiceClientConfig`. The parent is
///   the ambient server span and the tracer is the global provider, so a consumer who
///   enables tracing on `ModularApi` gets client spans without touching this package.
/// - **`X-Request-ID` is forwarded whether or not tracing is on** (runbook D23). `impulsa`
///   does not run modular_api, so trace context dies at that boundary — but if it logs the
///   request id it receives, log-level correlation survives a hop that traces cannot cross.
void main() {
  late TestHarness harness;
  late InMemorySpanExporter spans;
  late APITracer tracer;

  setUpAll(() async {
    harness = await maybeInitializeOtelForTest(serviceName: 'rest_client-test');
    spans = harness.spans;
    tracer = sdk.OTel.tracerProvider().getTracer('test-host');
    // The host does this from TracingOptions; here it is done directly, because what is
    // under test is that the client *reads* the global rather than owning a propagator.
    OTelAPI.textMapPropagator = _W3CInjector();
  });

  setUp(() => harness.clear());

  /// Captures the headers the client actually sent.
  late Map<String, String> sentHeaders;

  HttpServiceClient clientFor({
    int status = 200,
    Map<String, String> defaultHeaders = const <String, String>{},
    Object? throwError,
  }) {
    sentHeaders = <String, String>{};
    return HttpServiceClient(
      ServiceClientConfig(
        serviceId: 'impulsa',
        baseUrl: Uri.parse('https://impulsa.example/api'),
        redactedSummary: 'impulsa.example',
        defaultHeaders: defaultHeaders,
      ),
      httpClient: MockClient((request) async {
        sentHeaders = Map<String, String>.from(request.headers);
        if (throwError != null) throw throwError;
        return http.Response(jsonEncode({'ok': true}), status);
      }),
    );
  }

  Future<ServiceResult<ServiceResponse<Object?>>> call(
    HttpServiceClient client, {
    String operationId = 'get-cuenta-detalle',
  }) =>
      client.execute<Object?>(
        ServiceRequest(
          operationId: operationId,
          method: 'POST',
          path: operationId,
          body: {'dni': '12345678'},
        ),
        decoder: (json) => json,
      );

  group('with an active server span', () {
    Future<void> withinServerSpan(Future<void> Function() body) async {
      final serverSpan = tracer.startSpan('POST /api/cuenta/get-cuenta-detalle',
          kind: SpanKind.server);
      await tracer.withSpanAsync(serverSpan, body);
      serverSpan.end();
    }

    test('emits a client span named by method and operation', () async {
      await withinServerSpan(() async => call(clientFor()));

      expect(spans.spanNames, contains('POST get-cuenta-detalle'));
    });

    test('the client span is kind=client and a child of the server span', () async {
      await withinServerSpan(() async => call(clientFor()));

      final server = spans.findSpanByName('POST /api/cuenta/get-cuenta-detalle')!;
      final client = spans.findSpanByName('POST get-cuenta-detalle')!;

      expect(client.kind, equals(SpanKind.client));
      expect(
        client.spanContext.traceId.hexString,
        equals(server.spanContext.traceId.hexString),
      );
      expect(
        client.spanContext.parentSpanId?.hexString,
        equals(server.spanContext.spanId.hexString),
      );
    });

    test('records the upstream host, port and path, not the full URL', () async {
      // A full URL can carry identifiers in its path or query. server.address plus
      // url.path is what the conventions ask for and what is safe to store.
      await withinServerSpan(() async => call(clientFor()));

      final attributes = spans.findSpanByName('POST get-cuenta-detalle')!.attributes;

      expect(attributes.getString('server.address'), equals('impulsa.example'));
      expect(attributes.getString('url.path'), contains('get-cuenta-detalle'));
      expect(attributes.getString('http.request.method'), equals('POST'));
    });

    test('injects traceparent derived from the client span', () async {
      // The header the downstream service would read. It names the CLIENT span, not the
      // server span, so a downstream hop attaches to the call rather than to its parent.
      await withinServerSpan(() async => call(clientFor()));

      final client = spans.findSpanByName('POST get-cuenta-detalle')!;
      final traceparent = sentHeaders['traceparent'];

      expect(traceparent, isNotNull);
      expect(traceparent, contains(client.spanContext.traceId.hexString));
      expect(traceparent, contains(client.spanContext.spanId.hexString));
    });

    test('a 500 from upstream sets the client span to error', () async {
      await withinServerSpan(() async => call(clientFor(status: 500)));

      final client = spans.findSpanByName('POST get-cuenta-detalle')!;

      expect(client.status, equals(SpanStatusCode.Error));
      expect(client.attributes.getInt('http.response.status_code'), equals(500));
    });

    test('a 404 from upstream also sets error, unlike a server span', () async {
      // On a server span a 4xx is the caller's mistake. Here it means OUR outbound call
      // failed, which is a different thing and worth distinguishing when reading a
      // waterfall.
      await withinServerSpan(() async => call(clientFor(status: 404)));

      expect(
        spans.findSpanByName('POST get-cuenta-detalle')!.status,
        equals(SpanStatusCode.Error),
      );
    });

    test('a transport failure ends the span with error and no status code', () async {
      // The case that matters for the socia investigation: a call that never returns.
      // There is no status code to record, and it is unambiguously an error.
      await withinServerSpan(
        () async => call(clientFor(throwError: http.ClientException('connection reset'))),
      );

      final client = spans.findSpanByName('POST get-cuenta-detalle')!;

      expect(client.status, equals(SpanStatusCode.Error));
      expect(client.attributes.getInt('http.response.status_code'), isNull);
    });

    test('the span duration is the outbound call, which is the G7 measurement', () async {
      // What the whole tracing effort is for: separating "time spent calling impulsa" from
      // "time spent everywhere else". The assertion is only that the span is ended and
      // ordered inside its parent — the number itself is production's to report.
      await withinServerSpan(() async => call(clientFor()));

      final server = spans.findSpanByName('POST /api/cuenta/get-cuenta-detalle')!;
      final client = spans.findSpanByName('POST get-cuenta-detalle')!;

      expect(client.endTime, isNotNull);
      expect(
        client.startTime.isBefore(server.endTime!) ||
            client.startTime.isAtSameMomentAs(server.endTime!),
        isTrue,
      );
    });
  });

  group('X-Request-ID forwarding (D23)', () {
    test('an inbound request id is forwarded on the outbound call', () async {
      final client = clientFor(defaultHeaders: {requestIdHeader: 'order-42'});

      final serverSpan = tracer.startSpan('server', kind: SpanKind.server);
      await tracer.withSpanAsync(serverSpan, () async => call(client));
      serverSpan.end();

      expect(sentHeaders[requestIdHeader], equals('order-42'));
    });

    test('it is forwarded even with tracing off', () async {
      // The half of D23 that repairs D20: impulsa does not run modular_api, so trace
      // context dies there. If it logs the request id, log correlation still crosses the
      // boundary — and that must not depend on tracing being enabled.
      await call(clientFor(defaultHeaders: {requestIdHeader: 'order-42'}));

      expect(sentHeaders[requestIdHeader], equals('order-42'));
    });

    test('none is invented when the caller sent none', () async {
      // We forward, we do not generate. A chain with no request id keeps having none;
      // minting one belongs at an edge that knows it is the edge.
      await call(clientFor());

      expect(sentHeaders.containsKey(requestIdHeader), isFalse);
    });
  });

  group('without an active server span (gate G3)', () {
    test('no client span is emitted', () async {
      // Not "a non-recording span": none at all. Tracing off costs nothing here.
      await call(clientFor());

      expect(spans.spans, isEmpty);
    });

    test('no traceparent is injected', () async {
      // A header naming a span that does not exist would mislead a downstream service
      // into attaching to nothing.
      await call(clientFor());

      expect(sentHeaders.containsKey('traceparent'), isFalse);
    });

    test('the call still succeeds', () async {
      final result = await call(clientFor());

      expect(result.isSuccess, isTrue);
    });
  });
}

/// Minimal W3C injector, standing in for whatever the host configures globally.
///
/// The point of the test is that the client reads `OTelAPI.textMapPropagator` rather than
/// owning a propagator — this package does not depend on `modular_api` and so cannot reach
/// the framework's one (runbook D21).
class _W3CInjector implements TextMapPropagator<Map<String, String>, String> {
  @override
  List<String> fields() => const <String>['traceparent'];

  @override
  void inject(
    Context context,
    Map<String, String> carrier,
    TextMapSetter<String> setter,
  ) {
    final spanContext = context.spanContext;
    if (spanContext == null || !spanContext.isValid) return;
    final flags = spanContext.traceFlags.isSampled ? '01' : '00';
    setter.set(
      'traceparent',
      '00-${spanContext.traceId.hexString}-${spanContext.spanId.hexString}-$flags',
    );
  }

  @override
  Context extract(
    Context context,
    Map<String, String> carrier,
    TextMapGetter<String> getter,
  ) =>
      context;
}
