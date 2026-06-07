// ============================================================
// core/health/health_service.ts
// HealthService — evaluates checks in parallel with timeout.
// Mirror of health_service.dart in Dart.
// ============================================================

import { type HealthStatus, HealthCheck, HealthCheckResult, worstStatus } from './health_check';

/**
 * Aggregated health response following the IETF Health Check Response Format.
 *
 * `httpStatusCode`: 200 for pass/warn, 503 for fail.
 */
export class HealthResponse {
  readonly status: HealthStatus;
  readonly version: string;
  readonly releaseId: string;
  readonly checks: Record<string, HealthCheckResult>;

  constructor(options: {
    status: HealthStatus;
    version: string;
    releaseId: string;
    checks: Record<string, HealthCheckResult>;
  }) {
    this.status = options.status;
    this.version = options.version;
    this.releaseId = options.releaseId;
    this.checks = options.checks;
  }

  /** HTTP status code: 200 for pass/warn, 503 for fail. */
  get httpStatusCode(): number {
    return this.status === 'fail' ? 503 : 200;
  }

  /** Serialize to the IETF-compliant JSON structure. */
  toJson(): Record<string, any> {
    const checksJson: Record<string, unknown> = {};
    for (const [key, result] of Object.entries(this.checks)) {
      checksJson[key] = result.toJson();
    }
    return {
      status: this.status,
      version: this.version,
      releaseId: this.releaseId,
      checks: checksJson,
    };
  }
}

export interface HealthServiceOptions {
  /** API version string (e.g. '1.0.0'). */
  version: string;
  /**
   * Release identifier. Defaults to `version-debug`.
   * Override via `process.env.RELEASE_ID`.
   */
  releaseId?: string;
}

/**
 * Service that manages and evaluates {@link HealthCheck}s.
 *
 * Checks are executed in parallel with per-check timeout.
 * The overall status uses worst-status-wins aggregation: fail > warn > pass.
 *
 * ```ts
 * const service = new HealthService({ version: '1.0.0' });
 * service.addHealthCheck(new DatabaseHealthCheck());
 * const response = await service.evaluate();
 * ```
 */
export class HealthService {
  readonly version: string;
  readonly releaseId: string;
  private readonly checks: HealthCheck[] = [];

  constructor(options: HealthServiceOptions) {
    this.version = options.version;
    this.releaseId = options.releaseId ?? process.env.RELEASE_ID ?? `${options.version}-debug`;
  }

  /** Register a health check to be evaluated on each call to {@link evaluate}. */
  addHealthCheck(check: HealthCheck): void {
    this.checks.push(check);
  }

  /**
   * Execute all registered checks in parallel and return an aggregated
   * {@link HealthResponse}.
   */
  async evaluate(): Promise<HealthResponse> {
    if (this.checks.length === 0) {
      return new HealthResponse({
        status: 'pass',
        version: this.version,
        releaseId: this.releaseId,
        checks: {},
      });
    }

    const entries = await Promise.all(this.checks.map((c) => this.runCheck(c)));
    const checks: Record<string, HealthCheckResult> = {};
    for (const [name, result] of entries) {
      checks[name] = result;
    }

    // Worst-status-wins: fail > warn > pass
    const status = Object.values(checks)
      .map((r) => r.status)
      .reduce(worstStatus);

    return new HealthResponse({
      status,
      version: this.version,
      releaseId: this.releaseId,
      checks,
    });
  }

  /** Run a single check with timeout and timing. */
  private async runCheck(check: HealthCheck): Promise<[string, HealthCheckResult]> {
    const start = Date.now();
    try {
      const result = await this.withTimeout(check);
      const elapsed = Date.now() - start;
      return [check.name, result.withResponseTime(elapsed)];
    } catch (err) {
      const elapsed = Date.now() - start;
      return [
        check.name,
        new HealthCheckResult('fail', {
          responseTime: elapsed,
          output: String(err),
        }),
      ];
    }
  }

  /** Execute a check with its configured timeout. */
  private withTimeout(check: HealthCheck): Promise<HealthCheckResult> {
    return new Promise<HealthCheckResult>((resolve, reject) => {
      const timer = setTimeout(() => {
        resolve(
          new HealthCheckResult('fail', {
            output: `Health check "${check.name}" timeout after ${check.timeout}ms`,
          }),
        );
      }, check.timeout);

      check
        .check()
        .then((result) => {
          clearTimeout(timer);
          resolve(result);
        })
        .catch((err) => {
          clearTimeout(timer);
          reject(err);
        });
    });
  }
}
