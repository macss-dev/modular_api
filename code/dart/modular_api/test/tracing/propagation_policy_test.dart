import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:modular_api/src/core/tracing/propagation_policy.dart';
import 'package:modular_api/src/core/tracing/w3c_trace_context_propagator.dart';
import 'package:test/test.dart';

/// Tests for the propagation precedence policy.
///
/// Written and reviewed **before** any implementation exists. This is the second
/// and last `reviewBeforeImplementation` gate in the tracing work, and unlike
/// Stage 2 it keeps the gate for a specific reason: **this policy is ours.** No
/// reference implementation exists anywhere to check it against, so a wrong
/// expectation here becomes permanent wrong behaviour with nothing to catch it.
///
/// Three decisions live inside this class and each has cases below:
///
/// - **D6** — `X-Request-ID` is never adopted as the trace id.
/// - **D24** — the chain is a composable ordered list, first valid wins.
/// - **D25** — `trustIncomingTraceContext` gates whether incoming context is
///   honoured at all.
///
/// One design point the cases pin deliberately: **nothing is generated here.** When
/// no propagator matches, the result carries no span context and the tracer starts a
/// fresh trace with ids of its own. "Generate" is the tracer's step of the
/// precedence chain, not this class's, which is what keeps it allocation-free
/// (D7, G3).
void main() {
  const traceIdHex = '4bf92f3577b34da6a3ce929d0e0e4736';
  const spanIdHex = '00f067aa0ba902b7';
  const traceparent = '00-$traceIdHex-$spanIdHex-01';

  setUp(OTelAPI.reset);

  group('PropagationPolicy defaults', () {
    test('the default chain is W3C Trace Context alone', () {
      // Not W3C plus Cloud Trace: a Google propagator in core would contradict
      // roadmap invariant 7. A service on Cloud Run adds the external package.
      const policy = PropagationPolicy();

      expect(policy.propagators, hasLength(1));
      expect(policy.propagators.single, isA<W3CTraceContextPropagator>());
    });

    test('incoming trace context is trusted by default', () {
      expect(const PropagationPolicy().trustIncomingTraceContext, isTrue);
    });
  });

  group('resolution', () {
    test('accepts a remote parent from traceparent', () {
      final result = const PropagationPolicy().resolve({
        traceparentHeader: traceparent,
      });

      expect(result.hasRemoteParent, isTrue);
      expect(result.context.spanContext!.traceId.hexString, equals(traceIdHex));
      expect(result.context.spanContext!.spanId.hexString, equals(spanIdHex));
      expect(result.context.spanContext!.isRemote, isTrue);
    });

    test('carries no span context when no propagator matches', () {
      // The tracer generates ids for a root span. This class does not.
      final result = const PropagationPolicy().resolve(const {});

      expect(result.hasRemoteParent, isFalse);
      expect(result.context.spanContext, isNull);
    });

    test('carries no span context when the header is malformed', () {
      final result = const PropagationPolicy().resolve({
        traceparentHeader: 'not-a-traceparent',
      });

      expect(result.hasRemoteParent, isFalse);
    });

    test('resolves header names case-insensitively', () {
      final result = const PropagationPolicy().resolve({
        'TraceParent': traceparent,
      });

      expect(result.hasRemoteParent, isTrue);
    });
  });

  group('chain order (D24)', () {
    test('the first propagator to yield a valid context wins', () {
      final policy = PropagationPolicy(
        propagators: [
          _FixedPropagator(traceIdHex: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
          _FixedPropagator(traceIdHex: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'),
        ],
      );

      final result = policy.resolve(const {});

      expect(
        result.context.spanContext!.traceId.hexString,
        equals('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
      );
    });

    test('falls through to the next propagator when the first yields nothing', () {
      final policy = PropagationPolicy(
        propagators: [
          const _NeverMatchesPropagator(),
          const W3CTraceContextPropagator<Map<String, String>>(),
        ],
      );

      final result = policy.resolve({traceparentHeader: traceparent});

      expect(result.context.spanContext!.traceId.hexString, equals(traceIdHex));
    });

    test('a propagator that throws does not break resolution', () {
      // A third-party propagator is not our code. One misbehaving entry must not
      // fail a request; the chain continues.
      final policy = PropagationPolicy(
        propagators: [
          const _ThrowingPropagator(),
          const W3CTraceContextPropagator<Map<String, String>>(),
        ],
      );

      final result = policy.resolve({traceparentHeader: traceparent});

      expect(result.context.spanContext!.traceId.hexString, equals(traceIdHex));
    });

    test('an empty chain resolves to a context with no span context', () {
      final result =
          const PropagationPolicy(propagators: []).resolve({
        traceparentHeader: traceparent,
      });

      expect(result.hasRemoteParent, isFalse);
    });
  });

  group('X-Request-ID is preserved, never adopted (D6)', () {
    const uuid = '3f2504e0-4f89-11d3-9a0c-0305e82c3301';

    test('is exposed as requestId', () {
      final result =
          const PropagationPolicy().resolve({requestIdHeader: uuid});

      expect(result.requestId, equals(uuid));
    });

    test('is null when the caller sent none', () {
      expect(const PropagationPolicy().resolve(const {}).requestId, isNull);
    });

    test('never becomes the trace id, even when it is a valid UUID', () {
      // Stripping the dashes from a v4 UUID would produce a structurally valid
      // trace id, which is exactly why this needs asserting rather than assuming.
      final result =
          const PropagationPolicy().resolve({requestIdHeader: uuid});

      expect(result.hasRemoteParent, isFalse);
      expect(result.context.spanContext, isNull);
    });

    test('does not override a trace id that arrived in traceparent', () {
      final result = const PropagationPolicy().resolve({
        traceparentHeader: traceparent,
        requestIdHeader: uuid,
      });

      expect(result.context.spanContext!.traceId.hexString, equals(traceIdHex));
      expect(result.requestId, equals(uuid));
    });

    test('a non-UUID value is preserved verbatim', () {
      // We do not validate the caller's correlation token. It is opaque to us.
      final result = const PropagationPolicy()
          .resolve({requestIdHeader: 'order-42/retry-3'});

      expect(result.requestId, equals('order-42/retry-3'));
    });

    test('the same request id twice does not produce one shared trace', () {
      // The retry case that motivated reversing D6: callers reuse X-Request-ID
      // deliberately as an idempotency key, so adopting it would merge unrelated
      // retries into a single trace with several unconnected trees.
      const policy = PropagationPolicy();

      final first = policy.resolve({requestIdHeader: uuid});
      final second = policy.resolve({requestIdHeader: uuid});

      expect(first.hasRemoteParent, isFalse);
      expect(second.hasRemoteParent, isFalse);
      expect(first.requestId, equals(second.requestId));
    });
  });

  group('trustIncomingTraceContext (D25)', () {
    test('when false, an incoming traceparent is ignored', () {
      const policy = PropagationPolicy(trustIncomingTraceContext: false);

      final result = policy.resolve({traceparentHeader: traceparent});

      expect(result.hasRemoteParent, isFalse);
      expect(result.context.spanContext, isNull);
    });

    test('when false, every propagator in the chain is skipped', () {
      final policy = PropagationPolicy(
        trustIncomingTraceContext: false,
        propagators: [_FixedPropagator(traceIdHex: traceIdHex)],
      );

      expect(policy.resolve(const {}).hasRemoteParent, isFalse);
    });

    test('when false, X-Request-ID is still preserved', () {
      // It was never trusted as identity, so there is nothing to distrust. Log
      // correlation and outbound forwarding (D23) keep working either way.
      const policy = PropagationPolicy(trustIncomingTraceContext: false);

      final result = policy.resolve({requestIdHeader: 'order-42'});

      expect(result.requestId, equals('order-42'));
    });
  });

  test('resolution allocates no span (D7, G3)', () {
    // The policy returns a context, never a span. Span creation is the middleware's
    // job and only happens when tracing is configured.
    final result = const PropagationPolicy().resolve({
      traceparentHeader: traceparent,
    });

    expect(result.context, isA<Context>());
    expect(result.context.spanContext, isA<SpanContext>());
  });
}

/// Always yields the same span context, regardless of the carrier.
class _FixedPropagator implements TextMapPropagator<Map<String, String>, String> {
  _FixedPropagator({required this.traceIdHex});

  final String traceIdHex;

  @override
  List<String> fields() => const <String>[];

  @override
  void inject(
    Context context,
    Map<String, String> carrier,
    TextMapSetter<String> setter,
  ) {}

  @override
  Context extract(
    Context context,
    Map<String, String> carrier,
    TextMapGetter<String> getter,
  ) =>
      context.withSpanContext(
        OTelAPI.spanContext(
          traceId: OTelAPI.traceIdFrom(traceIdHex),
          spanId: OTelAPI.spanIdFrom('00f067aa0ba902b7'),
          isRemote: true,
        ),
      );
}

/// Never yields anything, like a propagator whose header is absent.
class _NeverMatchesPropagator
    implements TextMapPropagator<Map<String, String>, String> {
  const _NeverMatchesPropagator();

  @override
  List<String> fields() => const <String>[];

  @override
  void inject(
    Context context,
    Map<String, String> carrier,
    TextMapSetter<String> setter,
  ) {}

  @override
  Context extract(
    Context context,
    Map<String, String> carrier,
    TextMapGetter<String> getter,
  ) =>
      context;
}

/// Misbehaves, to prove the chain survives a third party's bug.
class _ThrowingPropagator
    implements TextMapPropagator<Map<String, String>, String> {
  const _ThrowingPropagator();

  @override
  List<String> fields() => const <String>[];

  @override
  void inject(
    Context context,
    Map<String, String> carrier,
    TextMapSetter<String> setter,
  ) {}

  @override
  Context extract(
    Context context,
    Map<String, String> carrier,
    TextMapGetter<String> getter,
  ) =>
      throw StateError('a third-party propagator threw');
}
