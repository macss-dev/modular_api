import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';

/// Propagates Google Cloud's legacy `X-Cloud-Trace-Context` header.
///
/// The OTel API ships W3C `traceparent` and Baggage propagators but **no Google
/// Cloud propagator**, so this one is ours (verified against
/// `dartastic_opentelemetry_api` 0.9.1). Cloud Run injects both headers; W3C is
/// preferred and this is the documented fallback, which is why the precedence
/// policy in Stage 3 consults it second.
///
/// Format: `TRACE_ID/SPAN_ID;o=OPTIONS`, where
///
/// - `TRACE_ID` is 32 hex characters, case-insensitive per Google's docs;
/// - **`SPAN_ID` is the decimal representation of an unsigned 64-bit integer** —
///   not hex. Reading it as hex yields a wrong parent and a silently broken
///   waterfall, which is the single most likely defect in this file;
/// - `OPTIONS` carries `o=1` (parent sampled) or `o=0` (not sampled).
///
/// Header-name casing is deliberately **not** this class's concern. HTTP header
/// semantics belong to the carrier, so [fields] returns the lowercase canonical
/// name and lookup goes through the supplied [TextMapGetter]. Shelf already
/// normalises header names to lowercase.
class CloudTraceContextPropagator
    implements TextMapPropagator<Map<String, String>, String> {
  /// Creates a propagator for the legacy Google Cloud trace header.
  const CloudTraceContextPropagator();

  /// The carrier key this propagator reads and writes.
  static const String headerName = 'x-cloud-trace-context';

  static final RegExp _traceIdPattern = RegExp(r'^[0-9a-f]{32}$');
  static final RegExp _decimalPattern = RegExp(r'^[0-9]+$');
  static final String _invalidTraceId = '0' * 32;

  /// 2^64-1. The span id is an unsigned 64-bit integer, which Dart's signed
  /// `int` cannot hold, so the bound is compared as a [BigInt].
  static final BigInt _maxUnsigned64 = BigInt.parse('ffffffffffffffff', radix: 16);

  @override
  List<String> fields() => const <String>[headerName];

  @override
  void inject(
    Context context,
    Map<String, String> carrier,
    TextMapSetter<String> setter,
  ) {
    final spanContext = context.spanContext;
    if (spanContext == null || !spanContext.isValid) return;

    // Back to decimal, which is what makes this header Google's and not W3C's.
    final spanId =
        BigInt.parse(spanContext.spanId.hexString, radix: 16).toString();
    final option = spanContext.traceFlags.isSampled ? '1' : '0';

    setter.set(headerName, '${spanContext.traceId.hexString}/$spanId;o=$option');
  }

  @override
  Context extract(
    Context context,
    Map<String, String> carrier,
    TextMapGetter<String> getter,
  ) {
    // A malformed upstream header must never fail a request, so every exit is a
    // return of the untouched context and the whole body is guarded. The
    // specific validations below exist so the common cases are rejected on
    // intent rather than by catching an exception.
    try {
      final raw = getter.get(headerName);
      if (raw == null || raw.isEmpty) return context;

      final separator = raw.indexOf('/');
      if (separator <= 0) return context;

      // Google documents the trace id as case-insensitive hex; W3C requires
      // lowercase. Normalising here is the deliberate asymmetry (D3).
      final traceId = raw.substring(0, separator).toLowerCase();
      if (!_traceIdPattern.hasMatch(traceId) || traceId == _invalidTraceId) {
        return context;
      }

      var remainder = raw.substring(separator + 1);
      var sampled = false;

      final optionsAt = remainder.indexOf(';');
      if (optionsAt >= 0) {
        sampled = _isSampled(remainder.substring(optionsAt + 1));
        remainder = remainder.substring(0, optionsAt);
      }

      if (!_decimalPattern.hasMatch(remainder)) return context;

      final spanId = BigInt.parse(remainder);
      if (spanId <= BigInt.zero || spanId > _maxUnsigned64) return context;

      return context.withSpanContext(
        OTelAPI.spanContext(
          traceId: OTelAPI.traceIdFrom(traceId),
          spanId: OTelAPI.spanIdFrom(spanId.toRadixString(16).padLeft(16, '0')),
          traceFlags: OTelAPI.traceFlags(
            sampled ? TraceFlags.SAMPLED_FLAG : TraceFlags.NONE_FLAG,
          ),
          isRemote: true,
        ),
      );
    } catch (_) {
      return context;
    }
  }

  /// Reads the `o=` option, tolerating other options alongside it.
  static bool _isSampled(String options) {
    for (final option in options.split(';')) {
      final trimmed = option.trim();
      if (trimmed.startsWith('o=')) return trimmed.substring(2) == '1';
    }
    return false;
  }
}
