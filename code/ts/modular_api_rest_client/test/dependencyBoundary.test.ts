import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * Guards the dependency boundary for a satellite package (runbook D21).
 *
 * This package does **not** depend on `@macss/modular-api`, so it cannot inherit the
 * OpenTelemetry API transitively and must declare it itself. What it must never declare as a
 * runtime dependency is an OTel SDK, an exporter, `@opentelemetry/core`, gRPC or protobuf:
 * those belong to the application (ADR-0005 A2).
 *
 * `devDependencies` may carry them, and does — the in-memory exporter and a W3C propagator
 * are needed to observe instrumentation at all, since the API alone produces no-op spans
 * (D22).
 */
const manifest = JSON.parse(
  readFileSync(join(process.cwd(), 'package.json'), 'utf8'),
) as { dependencies?: Record<string, string> };

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
});
