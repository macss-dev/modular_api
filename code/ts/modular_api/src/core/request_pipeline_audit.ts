import type { Response } from 'express';

export interface ShortCircuitAuditEntry {
  pluginId: string;
  middlewareId: string;
  slot: string;
}

interface RequestPipelineAuditState {
  shortCircuit?: ShortCircuitAuditEntry;
}

export const REQUEST_PIPELINE_AUDIT_LOCALS_KEY = 'requestPipelineAudit';

export function ensureRequestPipelineAudit(res: Response): RequestPipelineAuditState {
  const existing = res.locals[REQUEST_PIPELINE_AUDIT_LOCALS_KEY] as RequestPipelineAuditState | undefined;
  if (existing) {
    return existing;
  }

  const created: RequestPipelineAuditState = {};
  res.locals[REQUEST_PIPELINE_AUDIT_LOCALS_KEY] = created;
  return created;
}

export function setShortCircuitCandidate(res: Response, candidate: ShortCircuitAuditEntry): void {
  ensureRequestPipelineAudit(res).shortCircuit = candidate;
}

export function clearShortCircuitCandidate(res: Response, middlewareId: string): void {
  const audit = ensureRequestPipelineAudit(res);
  if (audit.shortCircuit?.middlewareId === middlewareId) {
    delete audit.shortCircuit;
  }
}

export function readShortCircuitCandidate(res: Response): ShortCircuitAuditEntry | undefined {
  return ensureRequestPipelineAudit(res).shortCircuit;
}