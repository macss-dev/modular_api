import { HealthCheck, HealthCheckResult } from '../../src/index';

export class AlwaysPassHealthCheck extends HealthCheck {
  readonly name = 'example';

  async check(): Promise<HealthCheckResult> {
    return new HealthCheckResult('pass');
  }
}
