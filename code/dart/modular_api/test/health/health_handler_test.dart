import 'dart:convert';
import 'package:test/test.dart';
import 'package:modular_api/modular_api.dart';

void main() {
  group('healthHandler — HTTP integration', () {
    test('GET /health returns 200 with application/health+json content-type',
        () async {
      final service = HealthService(version: '1.0.0');
      final handler = healthHandler(service);

      final request = Request('GET', Uri.parse('http://localhost/health'));
      final response = await handler(request);

      expect(response.statusCode, equals(200));
      expect(
        response.headers['content-type'],
        equals('application/health+json'),
      );
    });

    test('GET /health body is valid JSON with IETF structure', () async {
      final service = HealthService(version: '2.0.0', releaseId: '2.0.0-rc1');
      final handler = healthHandler(service);

      final request = Request('GET', Uri.parse('http://localhost/health'));
      final response = await handler(request);

      final body = jsonDecode(await response.readAsString());

      expect(body['status'], equals('pass'));
      expect(body['version'], equals('2.0.0'));
      expect(body['releaseId'], equals('2.0.0-rc1'));
      expect(body['checks'], isA<Map>());
    });

    test('GET /health returns 200 when checks pass', () async {
      final service = HealthService(version: '1.0.0');
      service.addHealthCheck(_FakeCheck('database', HealthStatus.pass));
      final handler = healthHandler(service);

      final request = Request('GET', Uri.parse('http://localhost/health'));
      final response = await handler(request);

      expect(response.statusCode, equals(200));

      final body = jsonDecode(await response.readAsString());
      expect(body['status'], equals('pass'));
      expect(body['checks']['database']['status'], equals('pass'));
    });

    test('GET /health returns 200 when status is warn', () async {
      final service = HealthService(version: '1.0.0');
      service.addHealthCheck(
        _FakeCheck('cache', HealthStatus.warn, output: 'high latency'),
      );
      final handler = healthHandler(service);

      final request = Request('GET', Uri.parse('http://localhost/health'));
      final response = await handler(request);

      expect(response.statusCode, equals(200));

      final body = jsonDecode(await response.readAsString());
      expect(body['status'], equals('warn'));
    });

    test('GET /health returns 503 when any check fails', () async {
      final service = HealthService(version: '1.0.0');
      service.addHealthCheck(_FakeCheck('database', HealthStatus.pass));
      service.addHealthCheck(_FakeCheck('redis', HealthStatus.fail));
      final handler = healthHandler(service);

      final request = Request('GET', Uri.parse('http://localhost/health'));
      final response = await handler(request);

      expect(response.statusCode, equals(503));

      final body = jsonDecode(await response.readAsString());
      expect(body['status'], equals('fail'));
    });

    test('GET /health includes all check results in response body', () async {
      final service = HealthService(version: '1.0.0');
      service.addHealthCheck(_FakeCheck('database', HealthStatus.pass));
      service.addHealthCheck(
        _FakeCheck('cache', HealthStatus.warn, output: 'high latency'),
      );
      service.addHealthCheck(_FakeCheck('queue', HealthStatus.pass));
      final handler = healthHandler(service);

      final request = Request('GET', Uri.parse('http://localhost/health'));
      final response = await handler(request);

      final body = jsonDecode(await response.readAsString());
      final checks = body['checks'] as Map<String, dynamic>;

      expect(checks.length, equals(3));
      expect(checks.containsKey('database'), isTrue);
      expect(checks.containsKey('cache'), isTrue);
      expect(checks.containsKey('queue'), isTrue);
    });

    test('GET /health check results include responseTime', () async {
      final service = HealthService(version: '1.0.0');
      service.addHealthCheck(_FakeCheck('database', HealthStatus.pass));
      final handler = healthHandler(service);

      final request = Request('GET', Uri.parse('http://localhost/health'));
      final response = await handler(request);

      final body = jsonDecode(await response.readAsString());
      // responseTime should be present and be an integer (ms)
      expect(body['checks']['database']['responseTime'], isA<int>());
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
