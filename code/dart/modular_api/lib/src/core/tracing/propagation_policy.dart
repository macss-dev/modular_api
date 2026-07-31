import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';

import 'w3c_trace_context_propagator.dart';

/// The header carrying a caller-supplied correlation id.
///
/// Read and preserved, **never** adopted as the trace id — see [PropagationPolicy].
const String requestIdHeader = 'x-request-id';

/// What resolving the incoming headers produced.
class PropagationResult {
  /// Creates a resolution result.
  const PropagationResult({required this.context, this.requestId});

  /// The context to continue with. Carries a remote parent when one was accepted,
  /// and otherwise carries none — trace and span id generation belongs to the
  /// tracer, not here.
  final Context context;

  /// The caller's `X-Request-ID`, when it sent one. Preserved for log correlation
  /// and for forwarding on outbound calls; it is not identity.
  final String? requestId;

  /// Whether a remote parent was accepted from the incoming headers.
  bool get hasRemoteParent => context.spanContext?.isValid ?? false;
}

/// Resolves incoming request headers into a tracing context.
///
/// **Composable rather than hardcoded** (runbook D24). The chain is an ordered
/// list of propagators and the first one to yield a valid span context wins. The
/// default is W3C Trace Context only: a service on Google Cloud adds the
/// `opentelemetry_propagator_gcp` package and puts its propagator in the list,
/// which keeps anything vendor-specific out of the framework. A service behind a
/// B3-speaking mesh adds a B3 propagator the same way, instead of forking.
///
/// **`X-Request-ID` is never the trace id** (runbook D6). It is read and preserved
/// beside the trace id, never promoted into it, for three reasons: callers reuse it
/// deliberately on retries, so adopting it would merge unrelated retries into one
/// trace; any client could then collide traces on purpose; and `trace_id` would
/// have ambiguous provenance, sometimes caller-supplied and sometimes generated,
/// with nothing in a log line to say which.
///
/// **Nothing is generated here.** When no propagator matches, the returned context
/// simply carries no span context, and the tracer starts a fresh trace with ids of
/// its own. That keeps this class allocation-free (runbook D7, gate G3).
class PropagationPolicy {
  /// Creates a policy.
  ///
  /// [propagators] defaults to W3C Trace Context alone. [trustIncomingTraceContext]
  /// defaults to `true`, matching every official OpenTelemetry SDK; set it to
  /// `false` on a service that receives internet traffic directly, where a caller
  /// could otherwise choose its trace ids (runbook D25).
  const PropagationPolicy({
    this.propagators = const <W3CTraceContextPropagator<Map<String, String>>>[
      W3CTraceContextPropagator<Map<String, String>>(),
    ],
    this.trustIncomingTraceContext = true,
  });

  /// The ordered chain. First valid span context wins.
  final List<TextMapPropagator<Map<String, String>, String>> propagators;

  /// Whether an incoming trace context is honoured at all (D25).
  final bool trustIncomingTraceContext;

  /// Resolves [headers] into a context plus the preserved request id.
  PropagationResult resolve(Map<String, String> headers) {
    throw UnimplementedError('step 3a: pending implementation');
  }
}
