import 'package:test/test.dart';
import 'package:modular_api/modular_api.dart';

void main() {
  group('HealthStatus', () {
    test('has exactly three values: pass, warn, fail', () {
      expect(HealthStatus.values.length, equals(3));
      expect(HealthStatus.values, contains(HealthStatus.pass));
      expect(HealthStatus.values, contains(HealthStatus.warn));
      expect(HealthStatus.values, contains(HealthStatus.fail));
    });

    test('pass < warn < fail in severity order', () {
      expect(HealthStatus.pass.index < HealthStatus.warn.index, isTrue);
      expect(HealthStatus.warn.index < HealthStatus.fail.index, isTrue);
    });
  });

  group('HealthCheckResult', () {
    test('creates a pass result with minimal fields', () {
      final result = HealthCheckResult(status: HealthStatus.pass);

      expect(result.status, equals(HealthStatus.pass));
      expect(result.responseTime, isNull);
      expect(result.output, isNull);
    });

    test('creates a warn result with output', () {
      final result = HealthCheckResult(
        status: HealthStatus.warn,
        output: 'high latency',
      );

      expect(result.status, equals(HealthStatus.warn));
      expect(result.output, equals('high latency'));
    });

    test('creates a fail result with responseTime and output', () {
      final result = HealthCheckResult(
        status: HealthStatus.fail,
        responseTime: 5000,
        output: 'connection refused',
      );

      expect(result.status, equals(HealthStatus.fail));
      expect(result.responseTime, equals(5000));
      expect(result.output, equals('connection refused'));
    });

    test('toJson() includes status always', () {
      final result = HealthCheckResult(status: HealthStatus.pass);
      final json = result.toJson();

      expect(json['status'], equals('pass'));
      expect(json.containsKey('responseTime'), isFalse);
      expect(json.containsKey('output'), isFalse);
    });

    test('toJson() includes responseTime when present', () {
      final result = HealthCheckResult(
        status: HealthStatus.pass,
        responseTime: 12,
      );
      final json = result.toJson();

      expect(json['status'], equals('pass'));
      expect(json['responseTime'], equals(12));
    });

    test('toJson() includes output when present', () {
      final result = HealthCheckResult(
        status: HealthStatus.warn,
        output: 'high latency',
      );
      final json = result.toJson();

      expect(json['status'], equals('warn'));
      expect(json['output'], equals('high latency'));
    });

    test('toJson() includes all fields when all present', () {
      final result = HealthCheckResult(
        status: HealthStatus.fail,
        responseTime: 5000,
        output: 'timeout',
      );
      final json = result.toJson();

      expect(json['status'], equals('fail'));
      expect(json['responseTime'], equals(5000));
      expect(json['output'], equals('timeout'));
    });
  });

  group('HealthCheck abstract class', () {
    test('default timeout is 5 seconds', () {
      final check = _PassingHealthCheck('test-check');
      expect(check.timeout, equals(const Duration(seconds: 5)));
    });

    test('custom timeout is respected', () {
      final check = _CustomTimeoutCheck('slow-check');
      expect(check.timeout, equals(const Duration(seconds: 10)));
    });

    test('name is preserved', () {
      final check = _PassingHealthCheck('database');
      expect(check.name, equals('database'));
    });

    test('check() returns a HealthCheckResult', () async {
      final check = _PassingHealthCheck('database');
      final result = await check.check();

      expect(result, isA<HealthCheckResult>());
      expect(result.status, equals(HealthStatus.pass));
    });
  });
}

// ─── Test doubles ─────────────────────────────────────────────────────────────

class _PassingHealthCheck extends HealthCheck {
  @override
  final String name;

  _PassingHealthCheck(this.name);

  @override
  Future<HealthCheckResult> check() async {
    return HealthCheckResult(status: HealthStatus.pass);
  }
}

class _CustomTimeoutCheck extends HealthCheck {
  @override
  final String name;

  @override
  Duration get timeout => const Duration(seconds: 10);

  _CustomTimeoutCheck(this.name);

  @override
  Future<HealthCheckResult> check() async {
    return HealthCheckResult(status: HealthStatus.pass);
  }
}
