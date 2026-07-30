import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:modular_api/src/core/tracing/cloud_trace_propagator.dart';
import 'package:test/test.dart';

/// Tests for the legacy `X-Cloud-Trace-Context` propagator.
///
/// Written and reviewed **before** any implementation exists
/// (`reviewBeforeImplementation`), because this is one of two places in the
/// tracing work where a wrong test becomes permanent wrong behaviour. The other
/// is the precedence policy in Stage 3.
///
/// The case that justifies the review gate is `SPAN_ID`: Google encodes it in
/// **decimal**, while every other id in tracing is hex. A test that asserted the
/// wrong conversion would lock in a broken parent link that still looks
/// plausible in a log line.
void main() {
  // A W3C-spec example trace id, used throughout so failures are readable.
  const traceIdHex = '4bf92f3577b34da6a3ce929d0e0e4736';

  setUp(OTelAPI.reset);

  group('CloudTraceContextPropagator', () {
    test('advertises the single carrier key it reads and writes', () {
      expect(
        const CloudTraceContextPropagator().fields(),
        equals(<String>[CloudTraceContextPropagator.headerName]),
      );
    });

    test('extracts a 32-hex trace id and a decimal span id', () {
      final context = _extract('$traceIdHex/1;o=1');
      final spanContext = context.spanContext;

      expect(spanContext, isNotNull);
      expect(spanContext!.traceId.hexString, equals(traceIdHex));
      expect(spanContext.spanId.hexString, equals('0000000000000001'));
    });

    test('reads the span id as decimal, not hex', () {
      // 1234567890 decimal is 0x499602D2. Read as hex it would be
      // 0x1234567890 -> '0000001234567890', which is the bug this asserts against.
      final spanContext = _extract('$traceIdHex/1234567890;o=1').spanContext;

      expect(spanContext!.spanId.hexString, equals('00000000499602d2'));
      expect(spanContext.spanId.hexString, isNot(equals('0000001234567890')));
    });

    test('handles a span id at the top of the unsigned 64-bit range', () {
      // 2^64-1. Dart's VM int is 64-bit *signed*, so a naive int.parse is wrong
      // here: the value must go through BigInt and keep its low 64 bits.
      final spanContext =
          _extract('$traceIdHex/18446744073709551615;o=1').spanContext;

      expect(spanContext!.spanId.hexString, equals('ffffffffffffffff'));
    });

    test('treats o=1 as sampled and o=0 as not sampled', () {
      expect(
        _extract('$traceIdHex/1;o=1').spanContext!.traceFlags.isSampled,
        isTrue,
      );
      expect(
        _extract('$traceIdHex/1;o=0').spanContext!.traceFlags.isSampled,
        isFalse,
      );
    });

    test('defaults to not sampled when the ;o= segment is absent', () {
      final spanContext = _extract('$traceIdHex/1').spanContext;

      expect(spanContext, isNotNull);
      expect(spanContext!.traceFlags.isSampled, isFalse);
    });

    test('accepts a case-insensitive trace id and normalises it to lowercase',
        () {
      // Google documents TRACE_ID as case-insensitive hex. This is the deliberate
      // asymmetry with W3C traceparent, which the spec requires to be lowercase
      // and which the OTel API's own propagator rejects when it is not.
      final spanContext =
          _extract('${traceIdHex.toUpperCase()}/1;o=1').spanContext;

      expect(spanContext!.traceId.hexString, equals(traceIdHex));
    });

    test('marks an extracted span context as remote', () {
      // The parent came from another process; without this the sampler and the
      // waterfall both treat it as locally created.
      expect(_extract('$traceIdHex/1;o=1').spanContext!.isRemote, isTrue);
    });

    group('leaves the context untouched rather than throwing', () {
      test('when the header is absent', () {
        expect(_extractFrom(const <String, String>{}).spanContext, isNull);
      });

      for (final malformed in <String, String>{
        'no span id segment': traceIdHex,
        'empty span id': '$traceIdHex/',
        'non-numeric span id': '$traceIdHex/abc',
        'span id beyond 64 bits': '$traceIdHex/18446744073709551616',
        'short trace id': 'abc/1',
        'non-hex trace id': 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz/1',
        'all-zero trace id': '${'0' * 32}/1',
        'all-zero span id': '$traceIdHex/0',
        'empty value': '',
        'unrelated garbage': 'not-a-trace-context',
      }.entries) {
        test('on ${malformed.key}', () {
          expect(_extract(malformed.value).spanContext, isNull);
        });
      }
    });

    test('injects the header back in Google\'s format', () {
      final carrier = <String, String>{};
      const CloudTraceContextPropagator().inject(
        OTelAPI.context().withSpanContext(
          OTelAPI.spanContext(
            traceId: OTelAPI.traceIdFrom(traceIdHex),
            spanId: OTelAPI.spanIdFrom('00000000499602d2'),
            traceFlags: OTelAPI.traceFlags(TraceFlags.SAMPLED_FLAG),
          ),
        ),
        carrier,
        _MapSetter(carrier),
      );

      expect(
        carrier[CloudTraceContextPropagator.headerName],
        equals('$traceIdHex/1234567890;o=1'),
      );
    });

    test('injects o=0 for a non-sampled span context', () {
      final carrier = <String, String>{};
      const CloudTraceContextPropagator().inject(
        OTelAPI.context().withSpanContext(
          OTelAPI.spanContext(
            traceId: OTelAPI.traceIdFrom(traceIdHex),
            spanId: OTelAPI.spanIdFrom('0000000000000001'),
            traceFlags: OTelAPI.traceFlags(TraceFlags.NONE_FLAG),
          ),
        ),
        carrier,
        _MapSetter(carrier),
      );

      expect(
        carrier[CloudTraceContextPropagator.headerName],
        equals('$traceIdHex/1;o=0'),
      );
    });

    test('injects nothing when there is no span context to propagate', () {
      final carrier = <String, String>{};
      const CloudTraceContextPropagator()
          .inject(OTelAPI.context(), carrier, _MapSetter(carrier));

      expect(carrier, isEmpty);
    });

    test('round-trips a value it produced', () {
      final carrier = <String, String>{};
      const propagator = CloudTraceContextPropagator();
      final original = OTelAPI.spanContext(
        traceId: OTelAPI.traceIdFrom(traceIdHex),
        spanId: OTelAPI.spanIdFrom('00000000499602d2'),
        traceFlags: OTelAPI.traceFlags(TraceFlags.SAMPLED_FLAG),
      );

      propagator.inject(
        OTelAPI.context().withSpanContext(original),
        carrier,
        _MapSetter(carrier),
      );
      final extracted = propagator
          .extract(OTelAPI.context(), carrier, _MapGetter(carrier))
          .spanContext;

      expect(extracted!.traceId.hexString, equals(original.traceId.hexString));
      expect(extracted.spanId.hexString, equals(original.spanId.hexString));
      expect(extracted.traceFlags.isSampled, isTrue);
    });
  });
}

Context _extract(String headerValue) =>
    _extractFrom({CloudTraceContextPropagator.headerName: headerValue});

Context _extractFrom(Map<String, String> carrier) =>
    const CloudTraceContextPropagator()
        .extract(OTelAPI.context(), carrier, _MapGetter(carrier));

/// A carrier reader with HTTP semantics: header names are case-insensitive.
///
/// Keeping that responsibility here rather than in the propagator is deliberate —
/// header casing belongs to the carrier. Shelf already lowercases header names.
class _MapGetter implements TextMapGetter<String> {
  const _MapGetter(this._carrier);

  final Map<String, String> _carrier;

  @override
  String? get(String key) {
    final wanted = key.toLowerCase();
    for (final entry in _carrier.entries) {
      if (entry.key.toLowerCase() == wanted) return entry.value;
    }
    return null;
  }

  @override
  Iterable<String> keys() => _carrier.keys;
}

class _MapSetter extends TextMapSetter<String> {
  _MapSetter(this._carrier);

  final Map<String, String> _carrier;

  @override
  void set(String key, String value) => _carrier[key] = value;
}
