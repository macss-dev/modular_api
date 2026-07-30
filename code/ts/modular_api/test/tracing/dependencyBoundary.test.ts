import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { describe, expect, it } from 'vitest';

/**
 * Guards the dependency boundary that ADR-0005 (as amended, A1 and A2) rests on.
 *
 * Core depends on the OpenTelemetry **API** — which is no-op when no SDK is
 * registered, so a consumer who never enables tracing pays nothing — and never
 * on an OpenTelemetry **SDK**, an exporter, gRPC or protobuf. Those belong to
 * the application, which supplies a configured TracerProvider through
 * TracingOptions.
 *
 * The Dart counterpart is `test/tracing/dependency_boundary_test.dart`. Same
 * assertions, idiomatic implementation.
 *
 * Two deliberate details:
 *
 * - The manifest is the subject, not `node_modules`. `@opentelemetry/api` is
 *   already present in the installed tree as a transitive dependency of vitest,
 *   so presence on disk proves nothing about what this package declares.
 * - Only `dependencies` is checked for the SDK prohibition. A `devDependency` on
 *   the SDK is legitimate — it does not ship to consumers, and the official
 *   in-memory span exporter used by tests lives there.
 */
const manifestPath = fileURLToPath(new URL('../../package.json', import.meta.url));
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
  dependencies?: Record<string, string>;
  devDependencies?: Record<string, string>;
};

const dependencies = manifest.dependencies ?? {};

describe('dependency boundary', () => {
  it('core declares the OpenTelemetry API', () => {
    expect(
      dependencies,
      'core instruments against the OTel API (ADR-0005 A1); without it there is no span contract to instrument with',
    ).toHaveProperty('@opentelemetry/api');
  });

  it('core declares no OpenTelemetry SDK or exporter as a runtime dependency', () => {
    const forbidden = Object.keys(dependencies).filter(
      (name) =>
        name.startsWith('@opentelemetry/sdk-') ||
        name.startsWith('@opentelemetry/exporter-') ||
        name === '@opentelemetry/resources' ||
        name === '@opentelemetry/core',
    );

    expect(
      forbidden,
      'the OTel SDK is the application\'s dependency, not the framework\'s (ADR-0005 A2)',
    ).toEqual([]);
  });

  it('core declares no gRPC or protobuf dependency', () => {
    const forbidden = Object.keys(dependencies).filter(
      (name) => name.startsWith('@grpc/') || name === 'protobufjs' || name === 'google-protobuf',
    );

    expect(
      forbidden,
      'core serialises nothing — the OTel SDK owns OTLP encoding (ADR-0005 A3); gRPC arrives with the planned gRPC transport, not with tracing',
    ).toEqual([]);
  });

  it('the OpenTelemetry API dependency is pinned to a range', () => {
    expect(
      dependencies['@opentelemetry/api'],
      'a floating `*` or `latest` would let a breaking version in silently',
    ).toMatch(/^\^\d+\.\d+\.\d+$/);
  });
});
