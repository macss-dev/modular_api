import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:modular_api/src/core/tracing/w3c_trace_context_propagator.dart';
import 'package:test/test.dart';

/// Tests for the W3C Trace Context propagator.
///
/// This exists because the Dart OTel **API** does not ship one — it is in the SDK,
/// which core must not depend on (ADR-0005 A2, runbook D26). Python's official
/// package puts an equivalent implementation in its API package, which is both the
/// argument that this belongs at the API layer and the oracle these cases are
/// checked against.
///
/// The format is exact, which is why this stage needs no review gate: 55
/// characters, `00-<32 hex>-<16 hex>-<2 hex>`, version `00` the only one defined,
/// lowercase hex only. Per D4 `tracestate` is carried verbatim and never parsed.
void main() {
  const traceIdHex = '4bf92f3577b34da6a3ce929d0e0e4736';
  const spanIdHex = '00f067aa0ba902b7';
  const sampled = '00-$traceIdHex-$spanIdHex-01';

  setUp(OTelAPI.reset);

  group('W3CTraceContextPropagator', () {
    test('advertises traceparent and tracestate as its fields', () {
      expect(
        const W3CTraceContextPropagator<Map<String, String>>().fields(),
        equals(<String>[traceparentHeader, tracestateHeader]),
      );
    });

    test('extracts trace id, parent span id and the sampled flag', () {
      final spanContext = _extract(sampled).spanContext;

      expect(spanContext, isNotNull);
      expect(spanContext!.traceId.hexString, equals(traceIdHex));
      expect(spanContext.spanId.hexString, equals(spanIdHex));
      expect(spanContext.traceFlags.isSampled, isTrue);
    });

    test('marks an extracted span context as remote', () {
      // Without this a foreign parent is treated as locally created, by both the
      // sampler and the backend.
      expect(_extract(sampled).spanContext!.isRemote, isTrue);
    });

    test('reads the sampled flag from bit 0 of the flags byte', () {
      expect(
        _extract('00-$traceIdHex-$spanIdHex-01').spanContext!.traceFlags.isSampled,
        isTrue,
      );
      expect(
        _extract('00-$traceIdHex-$spanIdHex-00').spanContext!.traceFlags.isSampled,
        isFalse,
      );
      // Unknown flags must not defeat the bit we do understand.
      expect(
        _extract('00-$traceIdHex-$spanIdHex-03').spanContext!.traceFlags.isSampled,
        isTrue,
      );
    });

    group('carries tracestate', () {
      test('verbatim, preserving order', () {
        // D4: we are not a tracing vendor, so we add no entry of our own and we
        // must not normalise, reorder or drop what another vendor set.
        //
        // Asserting the exact round-trip rather than mere presence, because W3C
        // makes tracestate ordering significant — the leftmost entry is the most
        // recently updated system. A `contains` check would pass even if the
        // order were scrambled, which is how this test was first written and what
        // writing the TypeScript mirror exposed.
        const raw = 'rojo=00f067aa0ba902b7,congo=t61rcWkgMzE';
        final spanContext = _extractWith(sampled, tracestate: raw).spanContext;

        expect(spanContext!.traceState?.toString(), equals(raw));
      });

      test('tolerating its absence', () {
        expect(_extract(sampled).spanContext, isNotNull);
      });
    });

    group('leaves the context untouched rather than throwing', () {
      test('when the header is absent', () {
        expect(_extractFrom(const <String, String>{}).spanContext, isNull);
      });

      for (final malformed in <String, String>{
        'unsupported version 01': '01-$traceIdHex-$spanIdHex-01',
        'unsupported version ff': 'ff-$traceIdHex-$spanIdHex-01',
        'short trace id': '00-abc-$spanIdHex-01',
        'short span id': '00-$traceIdHex-abc-01',
        'missing flags field': '00-$traceIdHex-$spanIdHex',
        'extra field': '00-$traceIdHex-$spanIdHex-01-extra',
        'non-hex trace id': '00-${'z' * 32}-$spanIdHex-01',
        'non-hex flags': '00-$traceIdHex-$spanIdHex-zz',
        'uppercase hex': '00-${traceIdHex.toUpperCase()}-$spanIdHex-01',
        'all-zero trace id': '00-${'0' * 32}-$spanIdHex-01',
        'all-zero span id': '00-$traceIdHex-${'0' * 16}-01',
        'empty value': '',
        'unrelated garbage': 'not-a-traceparent',
      }.entries) {
        test('on ${malformed.key}', () {
          expect(_extract(malformed.value).spanContext, isNull);
        });
      }
    });

    test('injects a valid traceparent', () {
      final carrier = _inject(
        OTelAPI.spanContext(
          traceId: OTelAPI.traceIdFrom(traceIdHex),
          spanId: OTelAPI.spanIdFrom(spanIdHex),
          traceFlags: OTelAPI.traceFlags(TraceFlags.SAMPLED_FLAG),
        ),
      );

      expect(carrier[traceparentHeader], equals(sampled));
    });

    test('injects flags 00 for a non-sampled span context', () {
      final carrier = _inject(
        OTelAPI.spanContext(
          traceId: OTelAPI.traceIdFrom(traceIdHex),
          spanId: OTelAPI.spanIdFrom(spanIdHex),
          traceFlags: OTelAPI.traceFlags(TraceFlags.NONE_FLAG),
        ),
      );

      expect(carrier[traceparentHeader], equals('00-$traceIdHex-$spanIdHex-00'));
    });

    test('injects tracestate only when one was received', () {
      final without = _inject(
        OTelAPI.spanContext(
          traceId: OTelAPI.traceIdFrom(traceIdHex),
          spanId: OTelAPI.spanIdFrom(spanIdHex),
        ),
      );
      expect(without.containsKey(tracestateHeader), isFalse);

      final with_ = _inject(
        OTelAPI.spanContext(
          traceId: OTelAPI.traceIdFrom(traceIdHex),
          spanId: OTelAPI.spanIdFrom(spanIdHex),
          traceState: OTelAPI.traceState({'rojo': '00f067aa0ba902b7'}),
        ),
      );
      expect(with_[tracestateHeader], contains('rojo'));
    });

    test('injects nothing when there is no span context to propagate', () {
      final carrier = <String, String>{};
      const W3CTraceContextPropagator<Map<String, String>>()
          .inject(OTelAPI.context(), carrier, _MapSetter(carrier));

      expect(carrier, isEmpty);
    });

    test('round-trips a value it produced', () {
      final original = OTelAPI.spanContext(
        traceId: OTelAPI.traceIdFrom(traceIdHex),
        spanId: OTelAPI.spanIdFrom(spanIdHex),
        traceFlags: OTelAPI.traceFlags(TraceFlags.SAMPLED_FLAG),
      );

      final extracted = _extractFrom(_inject(original)).spanContext;

      expect(extracted!.traceId.hexString, equals(original.traceId.hexString));
      expect(extracted.spanId.hexString, equals(original.spanId.hexString));
      expect(extracted.traceFlags.isSampled, isTrue);
    });
  });
}

Context _extract(String traceparent) =>
    _extractFrom({traceparentHeader: traceparent});

Context _extractWith(String traceparent, {required String tracestate}) =>
    _extractFrom({
      traceparentHeader: traceparent,
      tracestateHeader: tracestate,
    });

Context _extractFrom(Map<String, String> carrier) =>
    const W3CTraceContextPropagator<Map<String, String>>()
        .extract(OTelAPI.context(), carrier, _MapGetter(carrier));

Map<String, String> _inject(SpanContext spanContext) {
  final carrier = <String, String>{};
  const W3CTraceContextPropagator<Map<String, String>>().inject(
    OTelAPI.context().withSpanContext(spanContext),
    carrier,
    _MapSetter(carrier),
  );
  return carrier;
}

/// A carrier reader with HTTP semantics: header names are case-insensitive.
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
