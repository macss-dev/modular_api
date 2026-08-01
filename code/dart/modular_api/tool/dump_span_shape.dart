// Emits the span shape one representative request produces, as JSON on stdout.
//
// **Gate G6's input.** Three mirrored test suites can drift in a way no single-language test
// catches: a test asserts the attributes that *are* there and never the ones that are not, so an
// extra attribute in one language passes everywhere. This dump is compared key-for-key against
// `code/tests/fixtures/tracing/span_shape.json` by
// `code/tests/integration_test/tracing_parity_test.ps1`, which makes the exact attribute set —
// not a subset — the thing under test.
//
// Ids, timestamps and durations are deliberately excluded: they differ every run and are the SDK's
// business. Parentage is expressed by the parent's *name*, which is stable and is what a waterfall
// actually shows.
//
// Run: `dart run tool/dump_span_shape.dart`
// Counterparts: `code/ts/modular_api/tool/dumpSpanShape.ts`,
// `code/py/modular_api/tools/dump_span_shape.py`

import 'dart:convert';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as sdk;
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:http/http.dart' as http;
import 'package:modular_api/modular_api.dart';

Future<void> main() async {
  final harness = await maybeInitializeOtelForTest(serviceName: 'span-shape');

  final api = ModularApi(
    basePath: '/api',
    title: 'span-shape',
    tracing: TracingOptions(tracerProvider: sdk.OTel.tracerProvider()),
  );
  api.module('cuenta', (m) {
    m.usecase(
      'detalle',
      _DetalleUseCase.fromJson,
      inputExample: _DetalleInput(dni: '1'),
      outputExample: _DetalleOutput(echo: '1'),
    );
  });

  final server = await api.serve(port: 0);
  try {
    await http.post(
      Uri.parse('http://127.0.0.1:${server.port}/api/cuenta/detalle'),
      headers: {
        'content-type': 'application/json',
        // Sent so `http.request.header.x-request-id` is part of the shape. Without it the
        // attribute is conditionally absent in all three, and the comparison would not cover the
        // one attribute whose presence depends on the request.
        'x-request-id': 'parity-fixture',
      },
      body: jsonEncode({'dni': '12345678'}),
    );
  } finally {
    await server.close(force: true);
  }

  final captured = harness.spans.spans;
  final spans = captured
      .map(
        (span) => <String, Object?>{
          'name': span.name,
          'kind': span.kind.name,
          'parent': _parentName(span, captured),
          // `attributes` is @visibleForTesting, and this script is test infrastructure in
          // everything but its directory — it exists only to feed the parity harness. Reading it
          // here rather than exporting through a processor keeps the dump a pure function of the
          // request.
          // ignore: invalid_use_of_visible_for_testing_member
          'attributeKeys': span.attributes
              .toList()
              .map((attribute) => attribute.key)
              .toList()
            ..sort(),
        },
      )
      .toList()
    ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));

  // Sentinel-prefixed, because the framework logs its own JSON lines to stdout and the harness must
  // not have to guess which line is the payload.
  stdout.writeln('SPAN_SHAPE_JSON:${jsonEncode({'spans': spans})}');
  exit(0);
}

/// The name of [span]'s parent, or `null` when it is a root.
///
/// By name rather than id, because ids are excluded from the fixture. A root reports an all-zero
/// parent id in Dart rather than null, so validity — not representation — is what decides.
String? _parentName(APISpan span, List<APISpan> all) {
  final parentId = span.spanContext.parentSpanId;
  if (parentId == null || !parentId.isValid) return null;

  for (final candidate in all) {
    if (candidate.spanContext.spanId.hexString == parentId.hexString) {
      return candidate.name;
    }
  }
  return '<unknown>';
}

class _DetalleInput extends Input {
  _DetalleInput({required this.dni});

  factory _DetalleInput.fromJson(Map<String, dynamic> json) =>
      _DetalleInput(dni: json['dni'] as String? ?? '');

  final String dni;

  @override
  Map<String, dynamic> toJson() => {'dni': dni};

  @override
  Map<String, dynamic> toSchema() => {
        'type': 'object',
        'properties': {
          'dni': {'type': 'string'},
        },
        'required': ['dni'],
      };
}

class _DetalleOutput extends Output {
  _DetalleOutput({required this.echo});

  final String echo;

  @override
  int get statusCode => 200;

  @override
  Map<String, dynamic> toJson() => {'echo': echo};

  @override
  Map<String, dynamic> toSchema() => {
        'type': 'object',
        'properties': {
          'echo': {'type': 'string'},
        },
        'required': ['echo'],
      };
}

/// Stands in for a handler that calls something downstream.
///
/// The nested span is created with the plain OTel API and no argument threaded in: reaching the
/// server span through ambient context alone is the mechanism `modular_api_rest_client` and
/// `modular_api_postgres` use, so comparing it across languages compares theirs too — without core
/// depending on them.
class _DetalleUseCase implements UseCase<_DetalleInput, _DetalleOutput> {
  _DetalleUseCase({required this.input});

  static _DetalleUseCase fromJson(Map<String, dynamic> json) =>
      _DetalleUseCase(input: _DetalleInput.fromJson(json));

  @override
  final _DetalleInput input;

  @override
  ModularLogger? logger;

  @override
  String? validate() => null;

  @override
  Future<_DetalleOutput> execute() async {
    final span = OTelAPI.tracerProvider()
        .getTracer('span-shape')
        .startSpan('upstream impulsa', kind: SpanKind.client);
    span.end();
    return _DetalleOutput(echo: input.dni);
  }
}
