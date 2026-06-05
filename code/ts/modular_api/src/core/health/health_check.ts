// ============================================================
// core/health/health_check.ts
// Health check types — IETF Health Check Response Format draft.
// Mirror of health_check.dart in Dart.
// ============================================================

/**
 * Health status values.
 *
 * - `'pass'` — The component is healthy.
 * - `'warn'` — The component is healthy but has a warning condition.
 * - `'fail'` — The component is unhealthy.
 */
export type HealthStatus = 'pass' | 'warn' | 'fail';

/** Severity order for worst-status-wins aggregation. */
const SEVERITY: Record<HealthStatus, number> = {
  pass: 0,
  warn: 1,
  fail: 2,
};

/** Compare two statuses and return the worse one. */
export function worstStatus(a: HealthStatus, b: HealthStatus): HealthStatus {
  return SEVERITY[a] >= SEVERITY[b] ? a : b;
}

/**
 * Result returned by a single {@link HealthCheck}.
 */
export class HealthCheckResult {
  readonly status: HealthStatus;
  readonly responseTime?: number;
  readonly output?: string;

  constructor(status: HealthStatus, options?: { responseTime?: number; output?: string }) {
    this.status = status;
    this.responseTime = options?.responseTime;
    this.output = options?.output;
  }

  /** Return a copy with `responseTime` set. */
  withResponseTime(ms: number): HealthCheckResult {
    return new HealthCheckResult(this.status, {
      responseTime: ms,
      output: this.output,
    });
  }

  /** Serialize to the IETF JSON structure. Only includes optional fields when defined. */
  toJson(): Record<string, unknown> {
    const json: Record<string, unknown> = { status: this.status };
    if (this.responseTime !== undefined) json.responseTime = this.responseTime;
    if (this.output !== undefined) json.output = this.output;
    return json;
  }
}

/**
 * Abstract base for custom health checks.
 *
 * Implementors must provide `name` and `check()`.
 * Override `timeout` to change the default 5 000 ms deadline.
 *
 * ```ts
 * class DatabaseHealthCheck extends HealthCheck {
 *   readonly name = 'database';
 *   async check() {
 *     await db.ping();
 *     return new HealthCheckResult('pass');
 *   }
 * }
 * ```
 */
export abstract class HealthCheck {
  /** Display name used as the key in the `checks` map. */
  abstract readonly name: string;

  /** Maximum time (ms) before the check is considered failed. Default: 5 000. */
  get timeout(): number {
    return 5000;
  }

  /** Execute the health check and return a result. */
  abstract check(): Promise<HealthCheckResult>;
}
