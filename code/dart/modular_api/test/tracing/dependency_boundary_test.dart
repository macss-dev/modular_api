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
    pubspec = File('pubspec.yaml').readAsStringSync();
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
