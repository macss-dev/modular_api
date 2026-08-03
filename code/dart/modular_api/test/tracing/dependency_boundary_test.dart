import 'dart:io';

import 'package:test/test.dart';

/// Guards the dependency boundary that ADR-0005 (as amended, A1 and A2) rests on.
///
/// Core depends on the OpenTelemetry **API** — which is no-op when no SDK is
/// installed, so a consumer who never enables tracing pays nothing — and never
/// on an OpenTelemetry **SDK**, an exporter, gRPC or protobuf. Those belong to
/// the application, which supplies a configured `TracerProvider` through
/// `TracingOptions`.
///
/// This mirrors `clean_room_driver_isolation_test.dart`, which polices the
/// database-driver boundary the same way. The difference is direction: there the
/// assertion is that nothing is declared, here one dependency must be present
/// and a specific family must be absent.
///
/// Without this test the boundary is a promise in a document. With it, adding
/// `dartastic_opentelemetry` to core fails the suite.
void main() {
  late String pubspec;

  setUpAll(() {
    // Only the runtime dependency section. A test-only dependency on the OTel SDK
    // is legitimate and necessary — with just the API installed, spans are no-ops
    // that record nothing, so instrumentation cannot be observed without a real
    // TracerProvider (runbook D22). What must never happen is that same package
    // appearing under `dependencies`.
    //
    // Reading the whole file, as this test first did, could not tell the two apart:
    // adding the SDK as a dev dependency failed the guard. The TypeScript and
    // Python guards already parsed their manifests and scoped to runtime
    // dependencies; this brings Dart up to their precision.
    pubspec = _runtimeDependencies(File('pubspec.yaml').readAsStringSync());
  });

  test('core declares the OpenTelemetry API', () {
    expect(
      pubspec,
      contains('dartastic_opentelemetry_api:'),
      reason: 'core instruments against the OTel API (ADR-0005 A1); without it '
          'there is no span contract to instrument with',
    );
  });

  test('core declares no OpenTelemetry SDK', () {
    // `dartastic_opentelemetry:` cannot match the API entry, whose key
    // continues as `_api:` before the colon.
    expect(
      pubspec,
      isNot(contains('dartastic_opentelemetry:')),
      reason: 'the OTel SDK is the application\'s dependency, not the '
          'framework\'s (ADR-0005 A2)',
    );
    expect(
      pubspec,
      isNot(contains('opentelemetry:')),
      reason: 'no alternative OTel SDK either',
    );
    expect(
      pubspec,
      isNot(contains('otlp_dart:')),
      reason: 'core owns no wire format (ADR-0005 A3)',
    );
  });

  test('core declares no gRPC or protobuf dependency', () {
    expect(
      pubspec,
      isNot(contains('grpc:')),
      reason: 'exporters live in the application; gRPC arrives with the planned '
          'gRPC transport, not with tracing',
    );
    expect(
      pubspec,
      isNot(contains('protobuf:')),
      reason: 'core serialises nothing — the OTel SDK owns OTLP encoding '
          '(ADR-0005 A3)',
    );
  });

  test('a dev-only OTel SDK dependency does not trip the guard', () {
    // The point of scoping to runtime dependencies (D22). The SDK IS declared in
    // this package's dev_dependencies, and must stay invisible to the assertions
    // above while remaining forbidden under `dependencies`.
    final whole = File('pubspec.yaml').readAsStringSync();

    expect(whole, contains('dartastic_opentelemetry: ^'));
    expect(_runtimeDependencies(whole), isNot(contains('dartastic_opentelemetry:')));
  });

  test('the OpenTelemetry API dependency is pinned to a range', () {
    final constraint = RegExp(
      r'dartastic_opentelemetry_api:\s*\^\d+\.\d+\.\d+',
    );

    expect(
      pubspec,
      matches(constraint),
      reason: 'the API is pre-1.0 and under donation review, so a rename is '
          'anticipated (ADR-0005 A6); `any` would let a breaking version in '
          'silently',
    );
  });
}

/// Extracts the `dependencies:` block from a pubspec, excluding
/// `dev_dependencies:` and everything after it.
///
/// Deliberately textual rather than YAML-parsed: pulling in a parser to read one
/// section would itself add a dependency to the package whose dependencies this
/// test exists to police.
String _runtimeDependencies(String pubspec) {
  final lines = pubspec.split('\n');
  final start = lines.indexWhere((line) => line.trimRight() == 'dependencies:');
  if (start < 0) return '';

  final block = <String>[];
  for (final line in lines.skip(start + 1)) {
    // A new top-level key ends the block. Blank lines and comments do not.
    final isTopLevelKey = line.isNotEmpty &&
        !line.startsWith(' ') &&
        !line.startsWith('#') &&
        line.contains(':');
    if (isTopLevelKey) break;
    block.add(line);
  }

  return block.join('\n');
}
