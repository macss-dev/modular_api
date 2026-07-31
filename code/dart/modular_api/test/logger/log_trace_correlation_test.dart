import 'dart:convert';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as sdk;
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:modular_api/src/core/logger/logger.dart';
import 'package:modular_api/src/core/logger/logging_middleware.dart';
import 'package:modular_api/src/core/tracing/propagation_policy.dart';
import 'package:modular_api/src/core/tracing/tracing_middleware.dart';
import 'package:modular_api/src/core/tracing/tracing_options.dart';
import 'package:modular_api/src/core/tracing/w3c_trace_context_propagator.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Tests for log↔trace correlation, and for the compatibility guarantee that makes
/// the log-format change safe (runbook D5, D5b).
///
/// **The ordering problem this stage had to solve.** `loggingMiddleware` is outermost,
/// so it creates the logger *before* the span exists — and it emits `request completed`
/// *after* the span has ended. Reading the ambient span at log time would therefore
/// leave the single most useful line, the one carrying `duration_ms`, with nothing to
/// correlate on.
///
/// The resolution: the **logger owns the trace id** for the whole request, resolved
/// once by `loggingMiddleware`, and the tracing middleware attaches the span id to
/// that same logger object. Every line then correlates, including the last one.
void main() {
  const traceIdHex = '4bf92f3577b34da6a3ce929d0e0e4736';
  const traceparent = '00-$traceIdHex-00f067aa0ba902b7-01';

  late TestHarness harness;
  late InMemorySpanExporter spans;

  setUpAll(() async {
    harness = await maybeInitializeOtelForTest(serviceName: 'modular_api-test');
    spans = harness.spans;
  });

  setUp(() => harness.clear());

  /// Runs a request through logging (+ tracing when [tracing] is given) and returns
  /// the decoded log lines.
  Future<List<Map<String, dynamic>>> logsFor({
    TracingOptions? tracing,
    Map<String, String> headers = const <String, String>{},
    void Function(Request request)? onRequest,
  }) async {
    final sink = StringBuffer();

    var pipeline = Pipeline().addMiddleware(
      loggingMiddleware(
        logLevel: LogLevel.debug,
        serviceName: 'modular_api-test',
        sink: sink,
        propagationPolicy: tracing?.policy,
      ),
    );
    if (tracing != null) {
      pipeline = pipeline.addMiddleware(
        tracingMiddleware(tracer: tracing.tracer, policy: tracing.policy),
      );
    }

    final handler = pipeline.addHandler((Request request) async {
      onRequest?.call(request);
      return Response.ok('');
    });

    await handler(
      Request('GET', Uri.parse('http://localhost/api/cuenta/ping'),
          headers: headers),
    );

    return sink
        .toString()
        .trim()
        .split('\n')
        .where((line) => line.isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();
  }

  TracingOptions tracingOptions() =>
      TracingOptions(tracerProvider: sdk.OTel.tracerProvider());

  group('without TracingOptions — the compatibility guarantee (D5b)', () {
    test('trace_id keeps its dashed-UUID shape', () async {
      // The whole point of gating the format change on adoption: a consumer who does
      // not enable tracing sees exactly what they saw before, so no log query, no
      // dashboard and no alert breaks.
      final logs = await logsFor();

      expect(logs, isNotEmpty);
      expect(
        logs.first['trace_id'] as String,
        matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-'
            r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
      );
    });

    test('an incoming traceparent is ignored, not adopted', () async {
      // Propagation runs only when there is something to propagate into (D7). Without
      // tracing there is no span, so honouring the header would change the log format
      // for no benefit.
      final logs = await logsFor(headers: {traceparentHeader: traceparent});

      expect(logs.first['trace_id'], isNot(equals(traceIdHex)));
    });

    test('no span_id is emitted', () async {
      final logs = await logsFor();

      expect(logs.first.containsKey('span_id'), isFalse);
    });

    test('X-Request-ID is still honoured as the trace_id, as it always was',
        () async {
      final logs = await logsFor(headers: {requestIdHeader: 'legacy-correlation'});

      expect(logs.first['trace_id'], equals('legacy-correlation'));
    });
  });

  group('with TracingOptions', () {
    test('trace_id is the 32-hex W3C id', () async {
      final logs = await logsFor(
        tracing: tracingOptions(),
        headers: {traceparentHeader: traceparent},
      );

      expect(logs.first['trace_id'], equals(traceIdHex));
    });

    test('trace_id is a generated 32-hex id when no header arrives', () async {
      final logs = await logsFor(tracing: tracingOptions());

      expect(logs.first['trace_id'] as String, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('request_id carries the original X-Request-ID', () async {
      // D6: the caller's token is preserved beside the trace id rather than promoted
      // into it, so anyone correlating by what they sent keeps working.
      final logs = await logsFor(
        tracing: tracingOptions(),
        headers: {requestIdHeader: 'order-42'},
      );

      expect(logs.first['request_id'], equals('order-42'));
      expect(logs.first['trace_id'], isNot(equals('order-42')));
    });

    test('request_id is absent when the caller sent none', () async {
      final logs = await logsFor(tracing: tracingOptions());

      expect(logs.first.containsKey('request_id'), isFalse);
    });

    test('the trace_id in the log equals the exported span trace id', () async {
      // The assertion the whole stage exists for. If these two ever disagree, a log
      // line points at a trace that does not contain it.
      final logs = await logsFor(tracing: tracingOptions());

      final span = spans.findSpanByName('GET /api/cuenta/ping')!;
      expect(logs.first['trace_id'], equals(span.spanContext.traceId.hexString));
    });

    group('span_id', () {
      test('is emitted on lines logged after the span exists', () async {
        final logs = await logsFor(tracing: tracingOptions());

        final span = spans.findSpanByName('GET /api/cuenta/ping')!;
        final completed = logs.firstWhere((log) => log['msg'] == 'request completed');

        expect(completed['span_id'], equals(span.spanContext.spanId.hexString));
      });

      test('reaches the request-completed line, which is emitted after the span ends',
          () async {
        // The ordering problem stated plainly. loggingMiddleware is outermost, so it
        // logs `request completed` after the span has already ended. Reading an ambient
        // span at log time would have left this line — the one carrying duration_ms —
        // uncorrelated. Attaching the span id to the logger object solves it.
        final logs = await logsFor(tracing: tracingOptions());
        final completed = logs.firstWhere((log) => log['msg'] == 'request completed');

        expect(completed['duration_ms'], isNotNull);
        expect(completed['span_id'], isNotNull);
      });

      test('is absent from request-received, logged before the span exists', () async {
        // Honest about the limit rather than papering over it: the first line cannot
        // carry a span id, because no span exists yet. It still carries trace_id, which
        // is what links it to the trace.
        final logs = await logsFor(tracing: tracingOptions());
        final received = logs.firstWhere((log) => log['msg'] == 'request received');

        expect(received.containsKey('span_id'), isFalse);
        expect(received['trace_id'], isNotNull);
      });
    });
  });

  group('the platform correlation field', () {
    test('is absent by default', () async {
      // Roadmap invariant 7: the framework emits open formats and nothing
      // vendor-specific. Google's field needs a project id the framework has no
      // business knowing.
      final logs = await logsFor(tracing: tracingOptions());

      expect(
        logs.first.keys.any((key) => key.contains('googleapis')),
        isFalse,
      );
    });

    test('is emitted when the application supplies a formatter', () async {
      final sink = StringBuffer();
      final tracing = tracingOptions();

      final handler = Pipeline()
          .addMiddleware(
            loggingMiddleware(
              logLevel: LogLevel.debug,
              serviceName: 'modular_api-test',
              sink: sink,
              propagationPolicy: tracing.policy,
              // What socia supplies: the GCP field, built from ids the framework
              // resolved and a project id only the application knows.
              traceFieldFormatter: (traceId, spanId) => {
                'logging.googleapis.com/trace':
                    'projects/sociacacsi/traces/$traceId',
                if (spanId != null) 'logging.googleapis.com/spanId': spanId,
              },
            ),
          )
          .addMiddleware(
            tracingMiddleware(tracer: tracing.tracer, policy: tracing.policy),
          )
          .addHandler((Request request) async => Response.ok(''));

      await handler(Request('GET', Uri.parse('http://localhost/api/cuenta/ping')));

      final logs = sink
          .toString()
          .trim()
          .split('\n')
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();

      final completed = logs.firstWhere((log) => log['msg'] == 'request completed');
      expect(
        completed['logging.googleapis.com/trace'] as String,
        startsWith('projects/sociacacsi/traces/'),
      );
      expect(completed['logging.googleapis.com/spanId'], isNotNull);
    });

    test('is not emitted without tracing, even when a formatter is supplied',
        () async {
      // A formatter with no trace context to format would produce a field pointing at
      // a trace that does not exist.
      final sink = StringBuffer();

      final handler = Pipeline()
          .addMiddleware(
            loggingMiddleware(
              logLevel: LogLevel.debug,
              serviceName: 'modular_api-test',
              sink: sink,
              traceFieldFormatter: (traceId, spanId) => {
                'logging.googleapis.com/trace': 'projects/x/traces/$traceId',
              },
            ),
          )
          .addHandler((Request request) async => Response.ok(''));

      await handler(Request('GET', Uri.parse('http://localhost/api/cuenta/ping')));

      final logs = sink
          .toString()
          .trim()
          .split('\n')
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();

      expect(logs.first.containsKey('logging.googleapis.com/trace'), isFalse);
    });
  });
}
