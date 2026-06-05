import 'package:test/test.dart';
import 'package:modular_api/modular_api.dart';

void main() {
  group('HealthService', () {
    group('without checks', () {
      test('returns pass status with version and releaseId', () async {
        final service = HealthService(version: '1.0.0');
        final response = await service.evaluate();

        expect(response.status, equals(HealthStatus.pass));
        expect(response.version, equals('1.0.0'));
        expect(response.checks, isEmpty);
      });

      test('releaseId defaults to version-debug', () async {
        final service = HealthService(version: '1.0.0');
        final response = await service.evaluate();

        expect(response.releaseId, equals('1.0.0-debug'));
      });

      test('releaseId can be overridden', () async {
        final service = HealthService(
          version: '1.0.0',
          releaseId: '1.0.0-rc1',
        );
        final response = await service.evaluate();

        expect(response.releaseId, equals('1.0.0-rc1'));
      });
    });

    group('single check', () {
      test('pass check → overall pass', () async {
        final service = HealthService(version: '1.0.0');
        service.addHealthCheck(_FakeCheck('database', HealthStatus.pass));

        final response = await service.evaluate();

        expect(response.status, equals(HealthStatus.pass));
        expect(response.checks.containsKey('database'), isTrue);
        expect(response.checks['database']!.status, equals(HealthStatus.pass));
      });

      test('warn check → overall warn', () async {
        final service = HealthService(version: '1.0.0');
        service.addHealthCheck(
          _FakeCheck('cache', HealthStatus.warn, output: 'high latency'),
        );

        final response = await service.evaluate();

        expect(response.status, equals(HealthStatus.warn));
        expect(response.checks['cache']!.status, equals(HealthStatus.warn));
        expect(response.checks['cache']!.output, equals('high latency'));
      });

      test('fail check → overall fail', () async {
        final service = HealthService(version: '1.0.0');
        service.addHealthCheck(_FakeCheck('database', HealthStatus.fail));

        final response = await service.evaluate();

        expect(response.status, equals(HealthStatus.fail));
      });
    });

    group('multiple checks — worst-status-wins', () {
      test('pass + warn → overall warn', () async {
        final service = HealthService(version: '1.0.0');
        service.addHealthCheck(_FakeCheck('database', HealthStatus.pass));
        service.addHealthCheck(_FakeCheck('cache', HealthStatus.warn));

        final response = await service.evaluate();

        expect(response.status, equals(HealthStatus.warn));
        expect(response.checks.length, equals(2));
      });

      test('pass + fail → overall fail', () async {
        final service = HealthService(version: '1.0.0');
        service.addHealthCheck(_FakeCheck('database', HealthStatus.pass));
        service.addHealthCheck(_FakeCheck('redis', HealthStatus.fail));

        final response = await service.evaluate();

        expect(response.status, equals(HealthStatus.fail));
      });

      test('warn + fail → overall fail', () async {
        final service = HealthService(version: '1.0.0');
        service.addHealthCheck(_FakeCheck('cache', HealthStatus.warn));
        service.addHealthCheck(_FakeCheck('database', HealthStatus.fail));

        final response = await service.evaluate();

        expect(response.status, equals(HealthStatus.fail));
      });

      test('pass + pass + pass → overall pass', () async {
        final service = HealthService(version: '1.0.0');
        service.addHealthCheck(_FakeCheck('db', HealthStatus.pass));
        service.addHealthCheck(_FakeCheck('cache', HealthStatus.pass));
        service.addHealthCheck(_FakeCheck('queue', HealthStatus.pass));

        final response = await service.evaluate();

        expect(response.status, equals(HealthStatus.pass));
        expect(response.checks.length, equals(3));
      });
    });

    group('responseTime measurement', () {
      test('responseTime is measured in milliseconds', () async {
        final service = HealthService(version: '1.0.0');
        service.addHealthCheck(
          _SlowCheck('database', const Duration(milliseconds: 100)),
        );

        final response = await service.evaluate();

        expect(response.checks['database']!.responseTime, isNotNull);
        expect(response.checks['database']!.responseTime!,
            greaterThanOrEqualTo(90));
      });
    });

    group('timeout', () {
      test('check that exceeds timeout is marked as fail', () async {
        final service = HealthService(version: '1.0.0');
        // Check has 200ms timeout but takes 500ms
        service.addHealthCheck(
          _TimingOutCheck(
            'slow-db',
            delay: const Duration(milliseconds: 500),
            timeout: const Duration(milliseconds: 200),
          ),
        );

        final response = await service.evaluate();

        expect(response.status, equals(HealthStatus.fail));
        expect(response.checks['slow-db']!.status, equals(HealthStatus.fail));
        expect(
          response.checks['slow-db']!.output,
          contains('timeout'),
        );
      });

      test('check that completes within timeout works normally', () async {
        final service = HealthService(version: '1.0.0');
        service.addHealthCheck(
          _TimingOutCheck(
            'fast-db',
            delay: const Duration(milliseconds: 50),
            timeout: const Duration(seconds: 5),
          ),
        );

        final response = await service.evaluate();

        expect(response.checks['fast-db']!.status, equals(HealthStatus.pass));
      });
    });

    group('parallel execution', () {
      test('checks run in parallel, not sequentially', () async {
        final service = HealthService(version: '1.0.0');

        // Add 3 checks, each taking 200ms
        service.addHealthCheck(
          _SlowCheck('check1', const Duration(milliseconds: 200)),
        );
        service.addHealthCheck(
          _SlowCheck('check2', const Duration(milliseconds: 200)),
        );
        service.addHealthCheck(
          _SlowCheck('check3', const Duration(milliseconds: 200)),
        );

        final sw = Stopwatch()..start();
        await service.evaluate();
        sw.stop();

        // If sequential: ~600ms. If parallel: ~200ms.
        // Use a generous margin but confirm it's well under sequential time.
        expect(sw.elapsedMilliseconds, lessThan(500));
      });
    });

    group('exception handling', () {
      test('check that throws exception is marked as fail', () async {
        final service = HealthService(version: '1.0.0');
        service.addHealthCheck(_ThrowingCheck('broken'));

        final response = await service.evaluate();

        expect(response.status, equals(HealthStatus.fail));
        expect(response.checks['broken']!.status, equals(HealthStatus.fail));
        expect(response.checks['broken']!.output, isNotNull);
      });
    });
  });

  group('HealthResponse', () {
    test('toJson() produces IETF-compliant structure', () async {
      final service = HealthService(version: '2.0.0', releaseId: '2.0.0-rc1');
      service.addHealthCheck(_FakeCheck('database', HealthStatus.pass));
      service.addHealthCheck(
        _FakeCheck('cache', HealthStatus.warn, output: 'high latency'),
      );

      final response = await service.evaluate();
      final json = response.toJson();

      expect(json['status'], equals('warn'));
      expect(json['version'], equals('2.0.0'));
      expect(json['releaseId'], equals('2.0.0-rc1'));
      expect(json['checks'], isA<Map>());

      final checks = json['checks'] as Map<String, dynamic>;
      expect(checks['database']['status'], equals('pass'));
      expect(checks['cache']['status'], equals('warn'));
      expect(checks['cache']['output'], equals('high latency'));
    });

    test('httpStatusCode is 200 for pass', () async {
      final service = HealthService(version: '1.0.0');
      final response = await service.evaluate();

      expect(response.httpStatusCode, equals(200));
    });

    test('httpStatusCode is 200 for warn', () async {
      final service = HealthService(version: '1.0.0');
      service.addHealthCheck(_FakeCheck('cache', HealthStatus.warn));

      final response = await service.evaluate();

      expect(response.httpStatusCode, equals(200));
    });

    test('httpStatusCode is 503 for fail', () async {
      final service = HealthService(version: '1.0.0');
      service.addHealthCheck(_FakeCheck('db', HealthStatus.fail));

      final response = await service.evaluate();

      expect(response.httpStatusCode, equals(503));
    });
  });
}

// ─── Test doubles ─────────────────────────────────────────────────────────────

class _FakeCheck extends HealthCheck {
  @override
  final String name;
  final HealthStatus _status;
  final String? _output;

  _FakeCheck(this.name, this._status, {String? output}) : _output = output;

  @override
  Future<HealthCheckResult> check() async {
    return HealthCheckResult(status: _status, output: _output);
  }
}

class _SlowCheck extends HealthCheck {
  @override
  final String name;
  final Duration delay;

  _SlowCheck(this.name, this.delay);

  @override
  Future<HealthCheckResult> check() async {
    await Future.delayed(delay);
    return HealthCheckResult(status: HealthStatus.pass);
  }
}

class _TimingOutCheck extends HealthCheck {
  @override
  final String name;
  final Duration delay;
  final Duration _timeout;

  _TimingOutCheck(
    this.name, {
    required this.delay,
    required Duration timeout,
  }) : _timeout = timeout;

  @override
  Duration get timeout => _timeout;

  @override
  Future<HealthCheckResult> check() async {
    await Future.delayed(delay);
    return HealthCheckResult(status: HealthStatus.pass);
  }
}

class _ThrowingCheck extends HealthCheck {
  @override
  final String name;

  _ThrowingCheck(this.name);

  @override
  Future<HealthCheckResult> check() async {
    throw Exception('Connection refused');
  }
}
