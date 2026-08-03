import 'dart:io';

import 'package:test/test.dart';

/// Guards the dependency boundary for a satellite package (runbook D21).
///
/// This package does **not** depend on `modular_api`, so it cannot inherit the
/// OpenTelemetry API transitively and must declare it itself. What it must never declare is
/// an OTel SDK, an exporter, gRPC or protobuf: those belong to the application (ADR-0005
/// A2). A test-only SDK dependency is legitimate and is why this scopes to the runtime
/// section — with just the API installed spans are no-ops that record nothing, so a real
/// provider is the only way instrumentation is observable (D22).
void main() {
  late String runtimeDependencies;

  setUpAll(() {
    runtimeDependencies =
        _runtimeDependencies(File('pubspec.yaml').readAsStringSync());
  });

  test('declares the OpenTelemetry API directly', () {
    expect(
      runtimeDependencies,
      contains('dartastic_opentelemetry_api:'),
      reason: 'this package does not depend on modular_api, so the API cannot '
          'arrive transitively (D21)',
    );
  });

  test('declares no OpenTelemetry SDK, exporter, grpc or protobuf', () {
    for (final forbidden in const <String>[
      'dartastic_opentelemetry:',
      'opentelemetry:',
      'otlp_dart:',
      'grpc:',
      'protobuf:',
    ]) {
      expect(
        runtimeDependencies,
        isNot(contains(forbidden)),
        reason: '$forbidden belongs to the application, not the framework (A2)',
      );
    }
  });

  test('a dev-only OTel SDK dependency does not trip the guard', () {
    final whole = File('pubspec.yaml').readAsStringSync();

    expect(whole, contains('dartastic_opentelemetry: ^'));
    expect(runtimeDependencies, isNot(contains('dartastic_opentelemetry:')));
  });
}

/// Extracts the `dependencies:` block, excluding `dev_dependencies:` and after.
///
/// Textual rather than YAML-parsed: pulling in a parser to read one section would add a
/// dependency to the package whose dependencies this test exists to police.
String _runtimeDependencies(String pubspec) {
  final lines = pubspec.split('\n');
  final start = lines.indexWhere((line) => line.trimRight() == 'dependencies:');
  if (start < 0) return '';

  final block = <String>[];
  for (final line in lines.skip(start + 1)) {
    final isTopLevelKey = line.isNotEmpty &&
        !line.startsWith(' ') &&
        !line.startsWith('#') &&
        line.contains(':');
    if (isTopLevelKey) break;
    block.add(line);
  }

  return block.join('\n');
}
