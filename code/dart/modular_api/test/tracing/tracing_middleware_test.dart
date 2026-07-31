import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as sdk;
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:modular_api/src/core/tracing/propagation_policy.dart';
import 'package:modular_api/src/core/tracing/tracing_middleware.dart';
import 'package:modular_api/src/core/tracing/w3c_trace_context_propagator.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Tests for the host-owned server span.
///
/// First stage to use the SDK's own test harness (`maybeInitializeOtelForTest`),
/// which is also the pattern Stages 6 through 9 will follow: initialise once in
/// `setUpAll`, clear between cases, assert through `findSpanByName`. With only the
/// OTel API installed spans are no-ops that record nothing, so a real
/// `TracerProvider` is not optional here — it is the only way instrumentation is
/// observable at all (runbook D22).
///
/// The case this stage exists for is the enclosure regression test: a timestamp
/// taken inside a plugin middleware must fall within the server span's window.
/// ADR-0005 decision 4 was written because the first design would have failed it.
void main() {
  const traceIdHex = '4bf92f3577b34da6a3ce929d0e0e4736';
  const parentSpanIdHex = '00f067aa0ba902b7';

  late TestHarness harness;
  late InMemorySpanExporter spans;
  late APITracer tracer;

  setUpAll(() async {
    harness = await maybeInitializeOtelForTest(serviceName: 'modular_api-test');
    spans = harness.spans;
    tracer = sdk.OTel.tracerProvider().getTracer('modular_api');
  });

  setUp(() => harness.clear());

  /// Builds the pipeline the host builds: tracing immediately inside logging,
  /// then whatever [inner] middlewares a plugin would contribute.
  Handler pipelineFor(
    Handler handler, {
    List<String> excludedRoutes = const <String>[],
    List<Middleware> inner = const <Middleware>[],
  }) {
    var pipeline = Pipeline().addMiddleware(
      tracingMiddleware(tracer: tracer, excludedRoutes: excludedRoutes),
    );
    for (final middleware in inner) {
      pipeline = pipeline.addMiddleware(middleware);
    }
    return pipeline.addHandler(handler);
  }

  Future<Response> send(
    Handler handler, {
    String method = 'GET',
    String path = '/api/cuenta/get-cuenta-detalle',
    Map<String, String> headers = const <String, String>{},
  }) async =>
      handler(
        Request(method, Uri.parse('http://localhost$path'), headers: headers),
      );

  Handler okHandler([int status = 200]) =>
      (Request request) async => Response(status);

  group('the server span', () {
    test('is emitted for a request, named by method and route', () async {
      await send(pipelineFor(okHandler()));

      final span = spans.findSpanByName('GET /api/cuenta/get-cuenta-detalle');
      expect(span, isNotNull);
    });

    test('is a server span', () async {
      await send(pipelineFor(okHandler()));

      expect(
        spans.findSpanByName('GET /api/cuenta/get-cuenta-detalle')!.kind,
        equals(SpanKind.server),
      );
    });

    test('carries method, path and status code attributes', () async {
      await send(pipelineFor(okHandler()));

      final attributes =
          spans.findSpanByName('GET /api/cuenta/get-cuenta-detalle')!.attributes;

      expect(attributes.getString('http.request.method'), equals('GET'));
      expect(
        attributes.getString('url.path'),
        equals('/api/cuenta/get-cuenta-detalle'),
      );
      expect(attributes.getInt('http.response.status_code'), equals(200));
    });

    test('records the request id when the caller sent one', () async {
      // The semantic-convention name for a captured header, rather than an invented
      // one, so a reader of the trace recognises it (D6).
      await send(
        pipelineFor(okHandler()),
        headers: {requestIdHeader: 'order-42'},
      );

      expect(
        spans
            .findSpanByName('GET /api/cuenta/get-cuenta-detalle')!
            .attributes
            .getString('http.request.header.x-request-id'),
        equals('order-42'),
      );
    });

    test('omits the request id attribute when none was sent', () async {
      await send(pipelineFor(okHandler()));

      expect(
        spans
            .findSpanByName('GET /api/cuenta/get-cuenta-detalle')!
            .attributes
            .getString('http.request.header.x-request-id'),
        isNull,
      );
    });
  });

  group('parenting', () {
    test('is a child of an incoming traceparent', () async {
      // The precondition for reading cold start as a gap: our span must attach to
      // the platform's request span rather than starting a new trace.
      await send(
        pipelineFor(okHandler()),
        headers: {
          traceparentHeader: '00-$traceIdHex-$parentSpanIdHex-01',
        },
      );

      final span = spans.findSpanByName('GET /api/cuenta/get-cuenta-detalle')!;

      expect(span.spanContext.traceId.hexString, equals(traceIdHex));
      expect(span.spanContext.parentSpanId?.hexString, equals(parentSpanIdHex));
    });

    test('is a root span when no trace header arrives', () async {
      await send(pipelineFor(okHandler()));

      final span = spans.findSpanByName('GET /api/cuenta/get-cuenta-detalle')!;

      expect(span.spanContext.traceId.hexString, isNot(equals(traceIdHex)));
      // A root span reports an all-zero parent rather than a null one, which is the
      // OpenTelemetry convention for "no parent". Asserting `isNull` here would pass
      // only by accident on an implementation that chose the other representation.
      expect(span.spanContext.parentSpanId?.isValid ?? false, isFalse);
    });
  });

  group('status', () {
    test('a 5xx response sets the span status to error', () async {
      await send(pipelineFor(okHandler(503)));

      expect(
        spans.findSpanByName('GET /api/cuenta/get-cuenta-detalle')!.status,
        equals(SpanStatusCode.Error),
      );
    });

    test('a 4xx response does not set error status', () async {
      // A client mistake is not a server failure. Marking 404s as errors makes an
      // error-rate panel useless.
      await send(pipelineFor(okHandler(404)));

      expect(
        spans.findSpanByName('GET /api/cuenta/get-cuenta-detalle')!.status,
        isNot(equals(SpanStatusCode.Error)),
      );
    });

    test('an unhandled exception ends the span with error status and rethrows',
        () async {
      final handler = pipelineFor((Request request) async {
        throw StateError('boom');
      });

      await expectLater(send(handler), throwsA(isA<StateError>()));

      final span = spans.findSpanByName('GET /api/cuenta/get-cuenta-detalle');
      expect(span, isNotNull);
      expect(span!.status, equals(SpanStatusCode.Error));
    });
  });

  group('the span encloses everything inside it', () {
    test('a plugin middleware runs within the server span window', () async {
      // THE regression test for ADR-0005 decision 4. A span created from inside a
      // plugin slot would start after this middleware had already run, leaving the
      // waterfall blind to exactly the early work that matters.
      DateTime? observedInsidePlugin;

      Handler pluginMiddleware(Handler inner) => (Request request) {
            observedInsidePlugin = DateTime.now().toUtc();
            return inner(request);
          };

      await send(pipelineFor(okHandler(), inner: [pluginMiddleware]));

      final span = spans.findSpanByName('GET /api/cuenta/get-cuenta-detalle')!;

      expect(observedInsidePlugin, isNotNull);
      expect(
        observedInsidePlugin!.isBefore(span.endTime!) ||
            observedInsidePlugin!.isAtSameMomentAs(span.endTime!),
        isTrue,
        reason: 'the plugin middleware ran before the span ended',
      );
      expect(
        span.startTime.isBefore(observedInsidePlugin!) ||
            span.startTime.isAtSameMomentAs(observedInsidePlugin!),
        isTrue,
        reason: 'the span started before the plugin middleware ran',
      );
    });

    test('the span is ambient for downstream code', () async {
      // What makes Stages 8 and 9 possible without threading a span through call
      // signatures: a child created anywhere downstream attaches by itself.
      final handler = pipelineFor((Request request) async {
        tracer.startSpan('downstream.work').end();
        return Response.ok('');
      });

      await send(handler);

      final parent = spans.findSpanByName('GET /api/cuenta/get-cuenta-detalle')!;
      final child = spans.findSpanByName('downstream.work')!;

      expect(child.spanContext.traceId.hexString,
          equals(parent.spanContext.traceId.hexString));
      expect(child.spanContext.parentSpanId?.hexString,
          equals(parent.spanContext.spanId.hexString));
    });

    test('exposes the span and the propagation result in the request context',
        () async {
      Object? spanFromContext;
      Object? propagationFromContext;

      final handler = pipelineFor((Request request) async {
        spanFromContext = request.context[tracingSpanContextKey];
        propagationFromContext = request.context[propagationResultContextKey];
        return Response.ok('');
      });

      await send(handler, headers: {requestIdHeader: 'order-42'});

      expect(spanFromContext, isA<APISpan>());
      expect(propagationFromContext, isA<PropagationResult>());
      expect((propagationFromContext! as PropagationResult).requestId,
          equals('order-42'));
    });
  });

  group('excluded routes', () {
    test('produce no span', () async {
      // Health, metrics and docs are noise in a trace store, and the host derives
      // the list from operationalRoutePaths rather than hardcoding it.
      await send(
        pipelineFor(okHandler(), excludedRoutes: ['/api/health']),
        path: '/api/health',
      );

      expect(spans.spans, isEmpty);
    });

    test('still reach the handler', () async {
      var reached = false;

      await send(
        pipelineFor(
          (Request request) async {
            reached = true;
            return Response.ok('');
          },
          excludedRoutes: ['/api/health'],
        ),
        path: '/api/health',
      );

      expect(reached, isTrue);
    });
  });
}
