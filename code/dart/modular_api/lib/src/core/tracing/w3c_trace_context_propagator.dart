import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';

/// The W3C `traceparent` carrier key.
const String traceparentHeader = 'traceparent';

/// The W3C `tracestate` carrier key.
const String tracestateHeader = 'tracestate';

/// The only version defined by the W3C Trace Context recommendation.
const String _supportedVersion = '00';

/// `00-<32 hex>-<16 hex>-<2 hex>` — lowercase only, every field fixed-width.
final RegExp _traceparentPattern =
    RegExp(r'^([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$');

final String _invalidTraceId = '0' * 32;
final String _invalidSpanId = '0' * 16;

/// Propagates W3C Trace Context: `traceparent` and `tracestate`.
///
/// This is ours because the Dart OpenTelemetry **API** does not ship a
/// propagator — the W3C implementation lives in the SDK, which core must not
/// depend on (ADR-0005 A2, runbook D26). Python's official API package includes
/// an equivalent, which is both the argument that this belongs at the API layer
/// and the reference our behaviour is checked against.
///
/// The format is exact: 55 characters, `00-<trace id>-<parent span id>-<flags>`,
/// lowercase hex only, version `00` the only one defined. Anything else is
/// rejected, and rejection means *return the context unchanged* — a broken header
/// from an upstream caller must never fail a request.
///
/// `tracestate` is carried verbatim and never interpreted (runbook D4). We are not
/// a tracing vendor, so we add no entry of our own; normalising or reordering what
/// another vendor set would corrupt information we do not own.
///
/// Header-name casing is not this class's concern. HTTP header semantics belong to
/// the carrier, so [fields] reports lowercase canonical names and lookup goes
/// through the supplied [TextMapGetter]. Shelf already lowercases header names.
class W3CTraceContextPropagator<C> implements TextMapPropagator<C, String> {
  /// Creates a W3C Trace Context propagator.
  const W3CTraceContextPropagator();

  @override
  List<String> fields() =>
      const <String>[traceparentHeader, tracestateHeader];

  @override
  void inject(
    Context context,
    C carrier,
    TextMapSetter<String> setter,
  ) {
    final spanContext = context.spanContext;
    if (spanContext == null || !spanContext.isValid) return;

    final flags = spanContext.traceFlags.isSampled ? '01' : '00';
    setter.set(
      traceparentHeader,
      '$_supportedVersion-${spanContext.traceId.hexString}'
      '-${spanContext.spanId.hexString}-$flags',
    );

    // Only when there is something to carry. Emitting an empty tracestate would
    // be a header that says nothing.
    final traceState = spanContext.traceState;
    if (traceState != null) {
      final encoded = traceState.toString();
      if (encoded.isNotEmpty) setter.set(tracestateHeader, encoded);
    }
  }

  @override
  Context extract(
    Context context,
    C carrier,
    TextMapGetter<String> getter,
  ) {
    try {
      final raw = getter.get(traceparentHeader);
      if (raw == null || raw.isEmpty) return context;

      final match = _traceparentPattern.firstMatch(raw);
      if (match == null) return context;

      // Version 00 only. A future version may extend the format, and guessing at
      // an unknown layout is worse than starting a fresh trace.
      if (match.group(1) != _supportedVersion) return context;

      final traceId = match.group(2)!;
      final spanId = match.group(3)!;
      if (traceId == _invalidTraceId || spanId == _invalidSpanId) return context;

      // Bit 0 is `sampled`. Unknown bits must not defeat the one we understand.
      final flags = int.parse(match.group(4)!, radix: 16);
      final sampled = (flags & TraceFlags.SAMPLED_FLAG) == TraceFlags.SAMPLED_FLAG;

      return context.withSpanContext(
        OTelAPI.spanContext(
          traceId: OTelAPI.traceIdFrom(traceId),
          spanId: OTelAPI.spanIdFrom(spanId),
          traceFlags: OTelAPI.traceFlags(
            sampled ? TraceFlags.SAMPLED_FLAG : TraceFlags.NONE_FLAG,
          ),
          traceState: _extractTraceState(getter),
          isRemote: true,
        ),
      );
    } catch (_) {
      return context;
    }
  }

  /// Reads `tracestate` without parsing its grammar (D4).
  ///
  /// The value is split into entries only because [TraceState] is the shape the
  /// API stores; nothing is validated, reordered or dropped.
  TraceState? _extractTraceState(TextMapGetter<String> getter) {
    final raw = getter.get(tracestateHeader);
    if (raw == null || raw.trim().isEmpty) return null;

    final entries = <String, String>{};
    for (final member in raw.split(',')) {
      final separator = member.indexOf('=');
      if (separator <= 0) continue;
      entries[member.substring(0, separator).trim()] =
          member.substring(separator + 1).trim();
    }

    return entries.isEmpty ? null : OTelAPI.traceState(entries);
  }
}
