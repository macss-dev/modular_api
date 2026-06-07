import 'dart:convert';
import 'dart:io';

import 'package:modular_api_rest_client/modular_api_rest_client.dart';
import 'package:test/test.dart';

void main() {
  group('httpClient', () {
    test('sends a GET request, decodes JSON, and preserves metadata', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        expect(request.method, 'GET');
        expect(request.uri.path, '/users');
        expect(request.uri.queryParameters['name'], 'ana');
        expect(request.headers.value('x-default'), 'package');
        expect(request.headers.value('x-request'), 'test');

        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('x-request-id', 'req-123');
        request.response.write(jsonEncode({'ok': true, 'name': 'Ana'}));
        await request.response.close();
      });

      final config = ServiceClientConfig(
        serviceId: 'users',
        baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
        redactedSummary: 'users@local',
        defaultHeaders: const {'x-default': 'package'},
      );

      final request = ServiceRequest(
        operationId: 'get-users',
        method: 'GET',
        path: '/users',
        query: const {'name': 'ana'},
        headers: const {'x-request': 'test'},
      );

      final result = await httpClient<Map<String, Object?>>(
        config: config,
        request: request,
        decoder: (json) => Map<String, Object?>.from(json as Map),
      );

      expect(result.isSuccess, isTrue);
      expect(result.value.data['ok'], isTrue);
      expect(result.value.data['name'], 'Ana');
      expect(result.value.metadata.statusCode, HttpStatus.ok);
      expect(result.value.metadata.transportId, 'http');
      expect(result.value.metadata.requestId, 'req-123');
      expect(result.value.metadata.headers['x-request-id'], 'req-123');
    });

    test('returns a decode failure for invalid JSON responses', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{broken-json');
        await request.response.close();
      });

      final result = await httpClient<Object?>(
        config: ServiceClientConfig(
          serviceId: 'broken',
          baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
          redactedSummary: 'broken@local',
        ),
        request: const ServiceRequest(
          operationId: 'decode-failure',
          method: 'GET',
          path: '/broken',
        ),
      );

      expect(result.isFailure, isTrue);
      expect(result.failure.category, ServiceFailureCategory.decode);
      expect(result.failure.code, 'invalid_json');
    });

    test('injects auth headers from the auth provider', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        expect(request.headers.value('authorization'), 'Bearer token-123');

        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'ok': true}));
        await request.response.close();
      });

      final result = await httpClient<Map<String, Object?>>(
        config: ServiceClientConfig(
          serviceId: 'users',
          baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
          redactedSummary: 'users@local',
          authProvider: (operation) async {
            expect(operation.operationId, 'auth-check');
            return const {'authorization': 'Bearer token-123'};
          },
        ),
        request: const ServiceRequest(
          operationId: 'auth-check',
          method: 'GET',
          path: '/users',
        ),
        decoder: (json) => Map<String, Object?>.from(json as Map),
      );

      expect(result.isSuccess, isTrue);
      expect(result.value.data['ok'], isTrue);
    });

    test('returns a timeout failure when the request exceeds the configured timeout', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'late': true}));
        await request.response.close();
      });

      final result = await httpClient<Object?>(
        config: ServiceClientConfig(
          serviceId: 'slow',
          baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
          redactedSummary: 'slow@local',
          timeout: const Duration(milliseconds: 20),
        ),
        request: const ServiceRequest(
          operationId: 'timeout-check',
          method: 'GET',
          path: '/slow',
        ),
      );

      expect(result.isFailure, isTrue);
      expect(result.failure.category, ServiceFailureCategory.timeout);
      expect(result.failure.code, 'timeout');
      expect(result.failure.retryable, isTrue);
    });

    test('normalizes auth failures for non-2xx HTTP responses', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        request.response.statusCode = HttpStatus.unauthorized;
        request.response.write('missing token');
        await request.response.close();
      });

      final result = await httpClient<Object?>(
        config: ServiceClientConfig(
          serviceId: 'auth',
          baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
          redactedSummary: 'auth@local',
        ),
        request: const ServiceRequest(
          operationId: 'unauthorized',
          method: 'GET',
          path: '/auth',
        ),
      );

      expect(result.isFailure, isTrue);
      expect(result.failure.category, ServiceFailureCategory.auth);
      expect(result.failure.code, 'unauthorized');
      expect(result.failure.statusCode, HttpStatus.unauthorized);
      expect(result.failure.details, 'missing token');
    });

    test('normalizes rate-limit failures for non-2xx HTTP responses', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        request.response.statusCode = HttpStatus.tooManyRequests;
        request.response.write('retry later');
        await request.response.close();
      });

      final result = await httpClient<Object?>(
        config: ServiceClientConfig(
          serviceId: 'rate-limit',
          baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
          redactedSummary: 'rate-limit@local',
        ),
        request: const ServiceRequest(
          operationId: 'too-many',
          method: 'GET',
          path: '/rate-limit',
        ),
      );

      expect(result.isFailure, isTrue);
      expect(result.failure.category, ServiceFailureCategory.rateLimit);
      expect(result.failure.code, 'rate_limit');
      expect(result.failure.retryable, isTrue);
      expect(result.failure.statusCode, HttpStatus.tooManyRequests);
    });
  });

  group('HttpServiceClient', () {
    test('describes its config and closes cleanly', () async {
      final client = HttpServiceClient(
        ServiceClientConfig(
          serviceId: 'users',
          baseUrl: Uri.parse('https://example.test'),
          redactedSummary: 'users@example',
        ),
      );

      expect(client.describe().serviceId, 'users');
      expect(client.describe().transportId, 'http');

      final closed = await client.close();
      expect(closed.isSuccess, isTrue);
    });
  });
}