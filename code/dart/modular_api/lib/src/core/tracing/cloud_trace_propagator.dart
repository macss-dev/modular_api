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

  @override
  List<String> fields() {
    throw UnimplementedError('step 2a: pending implementation');
  }

  @override
  void inject(
    Context context,
    Map<String, String> carrier,
    TextMapSetter<String> setter,
  ) {
    throw UnimplementedError('step 2a: pending implementation');
  }

  @override
  Context extract(
    Context context,
    Map<String, String> carrier,
    TextMapGetter<String> getter,
  ) {
    throw UnimplementedError('step 2a: pending implementation');
  }
}
