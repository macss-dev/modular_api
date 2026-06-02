import 'package:shelf/shelf.dart';

const requestPipelineAuditContextKey = 'modular.requestPipelineAudit';

class ShortCircuitAuditEntry {
  final String pluginId;
  final String middlewareId;
  final String slot;

  const ShortCircuitAuditEntry({
    required this.pluginId,
    required this.middlewareId,
    required this.slot,
  });
}

class RequestPipelineAuditState {
  ShortCircuitAuditEntry? shortCircuit;
}

RequestPipelineAuditState? requestPipelineAuditFrom(Request request) {
  return request.context[requestPipelineAuditContextKey] as RequestPipelineAuditState?;
}

void setShortCircuitCandidate(Request request, ShortCircuitAuditEntry candidate) {
  requestPipelineAuditFrom(request)?.shortCircuit = candidate;
}

void clearShortCircuitCandidate(Request request, String middlewareId) {
  final audit = requestPipelineAuditFrom(request);
  if (audit?.shortCircuit?.middlewareId == middlewareId) {
    audit!.shortCircuit = null;
  }
}