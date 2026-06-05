from __future__ import annotations

from dataclasses import dataclass

from starlette.types import Scope

REQUEST_PIPELINE_AUDIT_STATE_KEY = "modular_pipeline_audit"


@dataclass
class ShortCircuitAuditEntry:
    plugin_id: str
    middleware_id: str
    slot: str


@dataclass
class RequestPipelineAuditState:
    short_circuit: ShortCircuitAuditEntry | None = None


def ensure_request_pipeline_audit(scope: Scope) -> RequestPipelineAuditState:
    state = scope.setdefault("state", {})
    audit = state.get(REQUEST_PIPELINE_AUDIT_STATE_KEY)
    if audit is None:
        audit = RequestPipelineAuditState()
        state[REQUEST_PIPELINE_AUDIT_STATE_KEY] = audit
    return audit


def set_short_circuit_candidate(scope: Scope, candidate: ShortCircuitAuditEntry) -> None:
    ensure_request_pipeline_audit(scope).short_circuit = candidate


def clear_short_circuit_candidate(scope: Scope, middleware_id: str) -> None:
    audit = ensure_request_pipeline_audit(scope)
    if audit.short_circuit is not None and audit.short_circuit.middleware_id == middleware_id:
        audit.short_circuit = None