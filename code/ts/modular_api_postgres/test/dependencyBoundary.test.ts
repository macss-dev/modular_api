import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * Guards the dependency boundary for a satellite package (runbook D21) **and ADR-0004**.
 *
 * This package does not depend on `@macss/modular-api`, so it cannot inherit the OpenTelemetry API
 * transitively and must declare it itself. What it must never declare as a runtime dependency is an
 * OTel SDK, an exporter, `@opentelemetry/core`, gRPC or protobuf: those belong to the application
 * (ADR-0005 A2). `devDependencies` may carry them, and does — the API alone produces no-op spans, so
 * a real provider is the only way instrumentation is observable at all (D22).
 *
 * **The driver guard is the reason this file is new.** ADR-0004 says this package ships contracts and
 * no database driver, and until now that was enforced by the package having no runtime dependencies
 * whatsoever — an invariant nobody had to assert because it was structural. Adding the OTel API ends
 * that, so the rule has to become a test. The runbook expected to extend an existing conformance
 * check; there was none to extend.
 */
const manifest = JSON.parse(
  readFileSync(join(process.cwd(), 'package.json'), 'utf8'),
) as { dependencies?: Record<string, string>; devDependencies?: Record<string, string> };

const dependencies = manifest.dependencies ?? {};

describe('dependency boundary', () => {
  it('declares the OpenTelemetry API directly', () => {
    expect(
      dependencies,
      'this package does not depend on modular_api, so the API cannot arrive transitively (D21)',
    ).toHaveProperty('@opentelemetry/api');
  });

  it('declares no OpenTelemetry SDK, exporter or core as a runtime dependency', () => {
    const forbidden = Object.keys(dependencies).filter(
      (name) =>
        name.startsWith('@opentelemetry/sdk-') ||
        name.startsWith('@opentelemetry/exporter-') ||
        name === '@opentelemetry/core' ||
        name === '@opentelemetry/resources',
    );

    expect(forbidden, 'those belong to the application, not the framework (A2)').toEqual([]);
  });

  it('declares no gRPC or protobuf dependency', () => {
    const forbidden = Object.keys(dependencies).filter(
      (name) => name.startsWith('@grpc/') || name === 'protobufjs',
    );

    expect(forbidden).toEqual([]);
  });

  it('declares no database driver (ADR-0004)', () => {
    // The invariant that makes instrumenting at the contract level worth anything: every
    // application-supplied adapter is instrumented for free precisely because this package never
    // talks to a database itself.
    const drivers = ['pg', 'pg-pool', 'postgres', 'mysql', 'mysql2', 'sqlite3', 'better-sqlite3', 'mssql', 'tedious'];
    const forbidden = Object.keys(dependencies).filter((name) => drivers.includes(name));

    expect(
      forbidden,
      'ADR-0004: this package ships contracts, the application ships the driver',
    ).toEqual([]);
  });

  it('a dev-only OTel SDK dependency does not trip the guard', () => {
    expect(manifest.devDependencies).toHaveProperty('@opentelemetry/sdk-trace-node');
    expect(dependencies).not.toHaveProperty('@opentelemetry/sdk-trace-node');
  });
});
