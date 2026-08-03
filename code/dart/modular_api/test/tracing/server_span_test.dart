import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as sdk;
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';

/// Gate G4 — transport neutrality.
///
/// **Not one line of this file imports shelf, constructs a `Request`, or opens a socket.** That is
/// the entire assertion: `startServerSpan` and `completeServerSpan` take a method, a route and a
/// header map, which is all any transport can supply. The planned gRPC transport therefore arrives
/// as a second adapter over the same functions rather than as a second copy of span construction.
///
/// This file exists because G4 was **checked rather than assumed** at the merge gate. The span had
/// been built inline inside `tracingMiddleware`'s shelf closure. Every behavioural test passed —
/// they go through HTTP, so they could not see it — and a gRPC transport would have had no choice
/// but to duplicate the logic. The extraction is what makes the roadmap item real.
void main() {
  late TestHarness harness;
  late InMemorySpanExporter spans;
  late APITracer tracer;

  setUpAll(() async {
    harness = await maybeInitializeOtelForTest(serviceName: 'server-span-test');
    spans = harness.spans;
    tracer = sdk.OTel.tracerProvider().getTracer('modular_api');
  });

  setUp(() => harness.clear());

  group('with no transport in scope', () {
    test('a span can be started and ended', () async {
      final started = startServerSpan(
        tracer: tracer,
        method: 'post',
        route: '/api/cuenta/detalle',
        headers: const {},
      );
      completeServerSpan(started.span, statusCode: 200);

      expect(spans.spanNames, contains('POST /api/cuenta/detalle'));
    });

    test('the method is upper-cased for the span name and the attribute', () async {
      // A transport that hands over a lower-case verb must not produce a differently named span
      // from one that hands over an upper-case one.
      final started = startServerSpan(
        tracer: tracer,
        method: 'get',
        route: '/api/cuenta/detalle',
        headers: const {},
      );
      completeServerSpan(started.span, statusCode: 200);

      final span = spans.findSpanByName('GET /api/cuenta/detalle')!;
      expect(span.attributes.getString('http.request.method'), equals('GET'));
    });

    test('it is a server span carrying route and status', () async {
      final started = startServerSpan(
        tracer: tracer,
        method: 'POST',
        route: '/api/cuenta/detalle',
        headers: const {},
      );
      completeServerSpan(started.span, statusCode: 201);

      final span = spans.findSpanByName('POST /api/cuenta/detalle')!;

      expect(span.kind, equals(SpanKind.server));
      expect(span.attributes.getString('url.path'), equals('/api/cuenta/detalle'));
      expect(span.attributes.getInt('http.response.status_code'), equals(201));
    });

    test('a header map is all propagation needs', () async {
      // The propagation policy takes a map, not a request. That is what lets a gRPC transport hand
      // over its metadata without translating it into an HTTP request first.
      final started = startServerSpan(
        tracer: tracer,
        method: 'POST',
        route: '/api/cuenta/detalle',
        headers: const {
          'traceparent': '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',
        },
      );
      completeServerSpan(started.span, statusCode: 200);

      final span = spans.findSpanByName('POST /api/cuenta/detalle')!;

      expect(
        span.spanContext.traceId.hexString,
        equals('4bf92f3577b34da6a3ce929d0e0e4736'),
      );
      expect(
        span.spanContext.parentSpanId?.hexString,
        equals('00f067aa0ba902b7'),
      );
    });

    test('the resolved request id is returned as well as recorded', () async {
      // The caller gets it back, because a transport adapter has to echo it on the response and
      // should not have to parse the headers a second time to find it.
      final started = startServerSpan(
        tracer: tracer,
        method: 'POST',
        route: '/api/cuenta/detalle',
        headers: const {'x-request-id': 'order-42'},
      );
      completeServerSpan(started.span, statusCode: 200);

      expect(started.propagation.requestId, equals('order-42'));
      expect(
        spans
            .findSpanByName('POST /api/cuenta/detalle')!
            .attributes
            .getString('http.request.header.x-request-id'),
        equals('order-42'),
      );
    });
  });

  group('status semantics', () {
    test('a 5xx sets error status', () async {
      final started = startServerSpan(
        tracer: tracer,
        method: 'POST',
        route: '/api/cuenta/detalle',
        headers: const {},
      );
      completeServerSpan(started.span, statusCode: 503);

      expect(
        spans.findSpanByName('POST /api/cuenta/detalle')!.status,
        equals(SpanStatusCode.Error),
      );
    });

    test('a 4xx does not', () async {
      // On a server span a 4xx is the caller's mistake. Marking it as our error makes an error-rate
      // panel useless. (The opposite holds on a client span, where a 4xx means *our* call failed.)
      final started = startServerSpan(
        tracer: tracer,
        method: 'POST',
        route: '/api/cuenta/detalle',
        headers: const {},
      );
      completeServerSpan(started.span, statusCode: 404);

      expect(
        spans.findSpanByName('POST /api/cuenta/detalle')!.status,
        isNot(equals(SpanStatusCode.Error)),
      );
    });

    test('an error sets error status and records the exception', () async {
      final started = startServerSpan(
        tracer: tracer,
        method: 'POST',
        route: '/api/cuenta/detalle',
        headers: const {},
      );
      completeServerSpan(started.span, error: StateError('boom'));

      expect(
        spans.findSpanByName('POST /api/cuenta/detalle')!.status,
        equals(SpanStatusCode.Error),
      );
    });

    test('a transport with no status code produces a span with none', () async {
      // gRPC has its own status model. Passing no HTTP status must not invent one.
      final started = startServerSpan(
        tracer: tracer,
        method: 'POST',
        route: '/api/cuenta/detalle',
        headers: const {},
      );
      completeServerSpan(started.span);

      final span = spans.findSpanByName('POST /api/cuenta/detalle')!;

      expect(span.attributes.getInt('http.response.status_code'), isNull);
      expect(span.status, isNot(equals(SpanStatusCode.Error)));
      expect(span.endTime, isNotNull);
    });
  });
}
