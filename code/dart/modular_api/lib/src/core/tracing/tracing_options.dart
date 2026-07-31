import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';

import '../logger/logger.dart';
import 'propagation_policy.dart';

/// Turns tracing on and says how.
///
/// **Absent means off, and off is free.** Without this, no tracing middleware is
/// installed, the OpenTelemetry API's no-op tracer is used, no span object is ever
/// created, and the log format is unchanged. A REST-only API that never asks for
/// tracing behaves exactly as it did before (ADR-0005 invariant 3, gate G3).
///
/// **The application supplies the tracer, not the framework** (ADR-0005 A2). Core
/// depends on the OpenTelemetry *API*; the SDK, its exporters and any credentials
/// belong to the application, which builds a provider and passes it here. On Cloud
/// Run that is typically `dartastic_opentelemetry` exporting to a Collector sidecar:
///
/// ```dart
/// await OTel.initialize(
///   serviceName: 'socia-api',
///   spanProcessor: BatchSpanProcessor(OtlpHttpSpanExporter(...)),
/// );
///
/// final api = ModularApi(
///   title: 'socia-api',
///   tracing: TracingOptions(tracerProvider: OTel.tracerProvider()),
/// );
/// ```
class TracingOptions {
  /// Creates tracing options.
  ///
  /// [tracerProvider] comes from the application's OpenTelemetry SDK.
  ///
  /// [propagators] defaults to W3C Trace Context alone. A service on Google Cloud
  /// appends a Cloud Trace propagator — the `opentelemetry_propagator_gcp` package
  /// provides one — which is how vendor-specific formats stay out of the framework
  /// (runbook D24, roadmap invariant 7).
  ///
  /// [trustIncomingTraceContext] defaults to `true`, matching every official
  /// OpenTelemetry SDK. **Set it to `false` on a service that receives internet
  /// traffic directly**, where a caller could otherwise choose its own trace ids
  /// and collide traces (runbook D25).
  ///
  /// [instrumentationName] identifies this instrumentation to the backend.
  const TracingOptions({
    required this.tracerProvider,
    List<TextMapPropagator<Map<String, String>, String>>? propagators,
    this.trustIncomingTraceContext = true,
    this.instrumentationName = 'modular_api',
    this.traceFieldFormatter,
  }) : _propagators = propagators;

  /// The application's tracer provider.
  final APITracerProvider tracerProvider;

  final List<TextMapPropagator<Map<String, String>, String>>? _propagators;

  /// Whether an incoming trace context is honoured at all (D25).
  final bool trustIncomingTraceContext;

  /// The instrumentation scope name reported to the backend.
  final String instrumentationName;

  /// Builds platform-specific log correlation fields, or `null` for none.
  ///
  /// The framework emits open formats and nothing vendor-specific (roadmap invariant
  /// 7), so a field like Google's `logging.googleapis.com/trace` — which needs a
  /// project id the framework has no business knowing — is produced here by the
  /// application:
  ///
  /// ```dart
  /// traceFieldFormatter: (traceId, spanId) => {
  ///   'logging.googleapis.com/trace': 'projects/my-project/traces/$traceId',
  ///   if (spanId != null) 'logging.googleapis.com/spanId': spanId,
  /// }
  /// ```
  final TraceFieldFormatter? traceFieldFormatter;

  /// The propagation policy these options describe.
  PropagationPolicy get policy => _propagators == null
      ? PropagationPolicy(
          trustIncomingTraceContext: trustIncomingTraceContext,
        )
      : PropagationPolicy(
          propagators: _propagators,
          trustIncomingTraceContext: trustIncomingTraceContext,
        );

  /// The tracer the host instruments with.
  APITracer get tracer => tracerProvider.getTracer(instrumentationName);
}
