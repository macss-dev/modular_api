import 'dart:convert';
import 'package:test/test.dart';
import 'package:modular_api/src/core/logger/logger.dart';

void main() {
  // ─── LogLevel enum ───────────────────────────────────────────────

  group('LogLevel', () {
    test('has exactly 8 values', () {
      expect(LogLevel.values.length, 8);
    });

    test('values map to RFC 5424 numeric severity', () {
      expect(LogLevel.emergency.value, 0);
      expect(LogLevel.alert.value, 1);
      expect(LogLevel.critical.value, 2);
      expect(LogLevel.error.value, 3);
      expect(LogLevel.warning.value, 4);
      expect(LogLevel.notice.value, 5);
      expect(LogLevel.info.value, 6);
      expect(LogLevel.debug.value, 7);
    });

    test('name returns lowercase string matching the enum name', () {
      expect(LogLevel.emergency.name, 'emergency');
      expect(LogLevel.alert.name, 'alert');
      expect(LogLevel.critical.name, 'critical');
      expect(LogLevel.error.name, 'error');
      expect(LogLevel.warning.name, 'warning');
      expect(LogLevel.notice.name, 'notice');
      expect(LogLevel.info.name, 'info');
      expect(LogLevel.debug.name, 'debug');
    });
  });

  // ─── RequestScopedLogger — filtering ─────────────────────────────

  group('RequestScopedLogger filtering', () {
    late StringBuffer output;

    setUp(() {
      output = StringBuffer();
    });

    test('logLevel=warning emits emergency, alert, critical, error, warning',
        () {
      final logger = RequestScopedLogger(
        traceId: 'trace-1',
        logLevel: LogLevel.warning,
        serviceName: 'test-svc',
        sink: output,
      );

      logger.emergency('e0');
      logger.alert('a1');
      logger.critical('c2');
      logger.error('e3');
      logger.warning('w4');

      final lines = output.toString().trim().split('\n');
      expect(lines.length, 5);
    });

    test('logLevel=warning suppresses notice, info, debug (total silence)', () {
      final logger = RequestScopedLogger(
        traceId: 'trace-1',
        logLevel: LogLevel.warning,
        serviceName: 'test-svc',
        sink: output,
      );

      logger.notice('n5');
      logger.info('i6');
      logger.debug('d7');

      expect(output.toString(), isEmpty);
    });

    test('logLevel=debug emits all 8 levels', () {
      final logger = RequestScopedLogger(
        traceId: 'trace-1',
        logLevel: LogLevel.debug,
        serviceName: 'test-svc',
        sink: output,
      );

      logger.emergency('e0');
      logger.alert('a1');
      logger.critical('c2');
      logger.error('e3');
      logger.warning('w4');
      logger.notice('n5');
      logger.info('i6');
      logger.debug('d7');

      final lines = output.toString().trim().split('\n');
      expect(lines.length, 8);
    });

    test('logLevel=emergency emits only emergency', () {
      final logger = RequestScopedLogger(
        traceId: 'trace-1',
        logLevel: LogLevel.emergency,
        serviceName: 'test-svc',
        sink: output,
      );

      logger.emergency('msg');
      logger.alert('msg');
      logger.critical('msg');
      logger.error('msg');
      logger.warning('msg');
      logger.notice('msg');
      logger.info('msg');
      logger.debug('msg');

      final lines = output.toString().trim().split('\n');
      expect(lines.length, 1);
    });
  });

  // ─── RequestScopedLogger — JSON format ───────────────────────────

  group('RequestScopedLogger JSON format', () {
    late StringBuffer output;

    setUp(() {
      output = StringBuffer();
    });

    test('each log is a single valid JSON line', () {
      final logger = RequestScopedLogger(
        traceId: 'trace-abc',
        logLevel: LogLevel.debug,
        serviceName: 'my-api',
        sink: output,
      );

      logger.info('hello world');

      final lines = output.toString().trim().split('\n');
      expect(lines.length, 1);

      // Must not throw
      final json = jsonDecode(lines[0]) as Map<String, dynamic>;
      expect(json, isA<Map<String, dynamic>>());
    });

    test('contains all mandatory fields: ts, level, severity, msg, service',
        () {
      final logger = RequestScopedLogger(
        traceId: 'trace-abc',
        logLevel: LogLevel.debug,
        serviceName: 'my-api',
        sink: output,
      );

      logger.info('test message');

      final json = jsonDecode(output.toString().trim()) as Map<String, dynamic>;
      expect(json.containsKey('ts'), isTrue);
      expect(json.containsKey('level'), isTrue);
      expect(json.containsKey('severity'), isTrue);
      expect(json.containsKey('msg'), isTrue);
      expect(json.containsKey('service'), isTrue);
    });

    test('ts is a float Unix timestamp with millisecond precision', () {
      final logger = RequestScopedLogger(
        traceId: 'trace-abc',
        logLevel: LogLevel.debug,
        serviceName: 'my-api',
        sink: output,
      );

      final before = DateTime.now().millisecondsSinceEpoch / 1000.0;
      logger.info('timing test');
      final after = DateTime.now().millisecondsSinceEpoch / 1000.0;

      final json = jsonDecode(output.toString().trim()) as Map<String, dynamic>;
      final ts = (json['ts'] as num).toDouble();
      expect(ts, greaterThanOrEqualTo(before));
      expect(ts, lessThanOrEqualTo(after + 0.01)); // small tolerance
    });

    test('level is lowercase string', () {
      final logger = RequestScopedLogger(
        traceId: 'trace-abc',
        logLevel: LogLevel.debug,
        serviceName: 'my-api',
        sink: output,
      );

      logger.warning('warn test');

      final json = jsonDecode(output.toString().trim()) as Map<String, dynamic>;
      expect(json['level'], 'warning');
    });

    test('severity matches the numeric RFC 5424 value', () {
      final logger = RequestScopedLogger(
        traceId: 'trace-abc',
        logLevel: LogLevel.debug,
        serviceName: 'my-api',
        sink: output,
      );

      logger.error('error test');

      final json = jsonDecode(output.toString().trim()) as Map<String, dynamic>;
      expect(json['severity'], 3);
    });

    test('msg contains the provided message', () {
      final logger = RequestScopedLogger(
        traceId: 'trace-abc',
        logLevel: LogLevel.debug,
        serviceName: 'my-api',
        sink: output,
      );

      logger.info('my descriptive message');

      final json = jsonDecode(output.toString().trim()) as Map<String, dynamic>;
      expect(json['msg'], 'my descriptive message');
    });

    test('service contains the configured service name', () {
      final logger = RequestScopedLogger(
        traceId: 'trace-abc',
        logLevel: LogLevel.debug,
        serviceName: 'payment-service',
        sink: output,
      );

      logger.info('svc test');

      final json = jsonDecode(output.toString().trim()) as Map<String, dynamic>;
      expect(json['service'], 'payment-service');
    });

    test('trace_id is included in every log', () {
      final logger = RequestScopedLogger(
        traceId: 'my-trace-id-123',
        logLevel: LogLevel.debug,
        serviceName: 'my-api',
        sink: output,
      );

      logger.info('trace test');

      final json = jsonDecode(output.toString().trim()) as Map<String, dynamic>;
      expect(json['trace_id'], 'my-trace-id-123');
    });

    test('fields are included when provided', () {
      final logger = RequestScopedLogger(
        traceId: 'trace-abc',
        logLevel: LogLevel.debug,
        serviceName: 'my-api',
        sink: output,
      );

      logger.info('with fields', fields: {'userId': 'u123', 'active': true});

      final json = jsonDecode(output.toString().trim()) as Map<String, dynamic>;
      expect(json['fields'], {'userId': 'u123', 'active': true});
    });

    test('fields key is absent when not provided', () {
      final logger = RequestScopedLogger(
        traceId: 'trace-abc',
        logLevel: LogLevel.debug,
        serviceName: 'my-api',
        sink: output,
      );

      logger.info('no fields');

      final json = jsonDecode(output.toString().trim()) as Map<String, dynamic>;
      expect(json.containsKey('fields'), isFalse);
    });

    test('each level produces correct level and severity pair', () {
      final levels = [
        ('emergency', 0),
        ('alert', 1),
        ('critical', 2),
        ('error', 3),
        ('warning', 4),
        ('notice', 5),
        ('info', 6),
        ('debug', 7),
      ];

      for (final (name, severity) in levels) {
        final buf = StringBuffer();
        final logger = RequestScopedLogger(
          traceId: 'trace-x',
          logLevel: LogLevel.debug,
          serviceName: 'svc',
          sink: buf,
        );

        // Call the method by name
        switch (name) {
          case 'emergency':
            logger.emergency('m');
          case 'alert':
            logger.alert('m');
          case 'critical':
            logger.critical('m');
          case 'error':
            logger.error('m');
          case 'warning':
            logger.warning('m');
          case 'notice':
            logger.notice('m');
          case 'info':
            logger.info('m');
          case 'debug':
            logger.debug('m');
        }

        final json = jsonDecode(buf.toString().trim()) as Map<String, dynamic>;
        expect(json['level'], name, reason: 'level should be "$name"');
        expect(json['severity'], severity,
            reason: 'severity for $name should be $severity');
      }
    });
  });

  // ─── RequestScopedLogger — additional fields for request logs ────

  group('RequestScopedLogger.logRequest', () {
    late StringBuffer output;

    setUp(() {
      output = StringBuffer();
    });

    test('logRequest emits request fields: method, route', () {
      final logger = RequestScopedLogger(
        traceId: 'trace-req',
        logLevel: LogLevel.debug,
        serviceName: 'my-api',
        sink: output,
      );

      logger.logRequest(method: 'POST', route: '/api/users/create');

      final json = jsonDecode(output.toString().trim()) as Map<String, dynamic>;
      expect(json['msg'], 'request received');
      expect(json['level'], 'info');
      expect(json['method'], 'POST');
      expect(json['route'], '/api/users/create');
      expect(json['trace_id'], 'trace-req');
    });

    test(
        'logResponse emits response fields: method, route, status, duration_ms',
        () {
      final logger = RequestScopedLogger(
        traceId: 'trace-res',
        logLevel: LogLevel.debug,
        serviceName: 'my-api',
        sink: output,
      );

      logger.logResponse(
        method: 'POST',
        route: '/api/users/create',
        statusCode: 200,
        durationMs: 45.3,
      );

      final json = jsonDecode(output.toString().trim()) as Map<String, dynamic>;
      expect(json['msg'], 'request completed');
      expect(json['method'], 'POST');
      expect(json['route'], '/api/users/create');
      expect(json['status'], 200);
      expect(json['duration_ms'], 45.3);
      expect(json['trace_id'], 'trace-res');
    });

    test('logResponse level is info for 2xx status', () {
      final logger = RequestScopedLogger(
        traceId: 't',
        logLevel: LogLevel.debug,
        serviceName: 's',
        sink: output,
      );

      logger.logResponse(
          method: 'GET', route: '/r', statusCode: 200, durationMs: 1.0);

      final json = jsonDecode(output.toString().trim()) as Map<String, dynamic>;
      expect(json['level'], 'info');
      expect(json['severity'], 6);
    });

    test('logResponse level is warning for 4xx status', () {
      final logger = RequestScopedLogger(
        traceId: 't',
        logLevel: LogLevel.debug,
        serviceName: 's',
        sink: output,
      );

      logger.logResponse(
          method: 'POST', route: '/r', statusCode: 404, durationMs: 2.0);

      final json = jsonDecode(output.toString().trim()) as Map<String, dynamic>;
      expect(json['level'], 'warning');
      expect(json['severity'], 4);
    });

    test('logResponse level is error for 5xx status', () {
      final logger = RequestScopedLogger(
        traceId: 't',
        logLevel: LogLevel.debug,
        serviceName: 's',
        sink: output,
      );

      logger.logResponse(
          method: 'POST', route: '/r', statusCode: 500, durationMs: 3.0);

      final json = jsonDecode(output.toString().trim()) as Map<String, dynamic>;
      expect(json['level'], 'error');
      expect(json['severity'], 3);
    });

    test('logResponse level is notice for 1xx status', () {
      final logger = RequestScopedLogger(
        traceId: 't',
        logLevel: LogLevel.debug,
        serviceName: 's',
        sink: output,
      );

      logger.logResponse(
          method: 'GET', route: '/r', statusCode: 100, durationMs: 0.5);

      final json = jsonDecode(output.toString().trim()) as Map<String, dynamic>;
      expect(json['level'], 'notice');
      expect(json['severity'], 5);
    });

    test('logResponse level is info for 3xx status', () {
      final logger = RequestScopedLogger(
        traceId: 't',
        logLevel: LogLevel.debug,
        serviceName: 's',
        sink: output,
      );

      logger.logResponse(
          method: 'GET', route: '/r', statusCode: 301, durationMs: 0.8);

      final json = jsonDecode(output.toString().trim()) as Map<String, dynamic>;
      expect(json['level'], 'info');
      expect(json['severity'], 6);
    });

    test('logRequest is suppressed when logLevel < info', () {
      final logger = RequestScopedLogger(
        traceId: 't',
        logLevel: LogLevel.warning,
        serviceName: 's',
        sink: output,
      );

      logger.logRequest(method: 'GET', route: '/r');

      expect(output.toString(), isEmpty);
    });

    test('logResponse with 5xx emits even when logLevel=error', () {
      final logger = RequestScopedLogger(
        traceId: 't',
        logLevel: LogLevel.error,
        serviceName: 's',
        sink: output,
      );

      logger.logResponse(
          method: 'POST', route: '/r', statusCode: 503, durationMs: 100.0);

      final json = jsonDecode(output.toString().trim()) as Map<String, dynamic>;
      expect(json['level'], 'error');
    });
  });
}
