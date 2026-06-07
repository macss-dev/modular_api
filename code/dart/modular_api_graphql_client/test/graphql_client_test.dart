import 'dart:convert';
import 'dart:io';

import 'package:modular_api_graphql_client/modular_api_graphql_client.dart';
import 'package:test/test.dart';

void main() {
  group('graphqlClient', () {
    test('sends a POST to /graphql and decodes the GraphQL envelope', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        expect(request.method, 'POST');
        expect(request.uri.path, '/graphql');
        expect(request.headers.value('x-default'), 'package');
        expect(request.headers.value('x-request'), 'test');

        final payload = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, Object?>;
        expect(payload['query'], 'query GetUsers { users { id } }');
        expect(payload['operationName'], 'GetUsers');
        expect(payload['variables'], {'limit': 10});

        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('x-request-id', 'req-graphql-1');
        request.response.write(
          jsonEncode({
            'data': {
              'users': [
                {'id': '1'}
              ]
            },
            'extensions': {'traceId': 'trace-1'}
          }),
        );
        await request.response.close();
      });

      final result = await graphqlClient<Map<String, Object?>>(
        config: ServiceClientConfig(
          serviceId: 'users-graphql',
          baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
          redactedSummary: 'users-graphql@local',
          defaultHeaders: const {'x-default': 'package'},
        ),
        request: const GraphqlRequest(
          operationId: 'users.query',
          document: 'query GetUsers { users { id } }',
          operationName: 'GetUsers',
          variables: {'limit': 10},
          headers: {'x-request': 'test'},
        ),
        decoder: (json) => Map<String, Object?>.from(json as Map),
      );

      expect(result.isSuccess, isTrue);
      expect(result.value.data!['users'], [
        {'id': '1'}
      ]);
      expect(result.value.errors, isEmpty);
      expect(result.value.extensions, {'traceId': 'trace-1'});
      expect(result.value.metadata.statusCode, HttpStatus.ok);
      expect(result.value.metadata.transportId, 'graphql');
      expect(result.value.metadata.requestId, 'req-graphql-1');
    });

    test(
      'preserves GraphQL errors without collapsing them into transport failures',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);

        server.listen((request) async {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'data': null,
              'errors': [
                {
                  'message': 'Field users is not available',
                  'path': ['users'],
                  'extensions': {'code': 'FIELD_UNAVAILABLE'}
                }
              ]
            }),
          );
          await request.response.close();
        });

        final result = await graphqlClient<Object?>(
          config: ServiceClientConfig(
            serviceId: 'users-graphql',
            baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
            redactedSummary: 'users-graphql@local',
          ),
          request: const GraphqlRequest(
            operationId: 'users.error',
            document: 'query Broken { users }',
          ),
        );

        expect(result.isSuccess, isTrue);
        expect(result.value.data, isNull);
        expect(result.value.errors, hasLength(1));
        expect(result.value.errors.first.message, 'Field users is not available');
        expect(result.value.errors.first.path, ['users']);
        expect(
          result.value.errors.first.extensions,
          {'code': 'FIELD_UNAVAILABLE'},
        );
      },
    );

    test('injects auth headers from the auth provider', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        expect(request.headers.value('authorization'), 'Bearer token-123');
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'data': {'ok': true}}));
        await request.response.close();
      });

      final result = await graphqlClient<Map<String, Object?>>(
        config: ServiceClientConfig(
          serviceId: 'users-graphql',
          baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
          redactedSummary: 'users-graphql@local',
          authProvider: (operation) async {
            expect(operation.operationId, 'users.auth');
            return const {'authorization': 'Bearer token-123'};
          },
        ),
        request: const GraphqlRequest(
          operationId: 'users.auth',
          document: 'query Viewer { viewer { id } }',
        ),
        decoder: (json) => Map<String, Object?>.from(json as Map),
      );

      expect(result.isSuccess, isTrue);
      expect(result.value.data!['ok'], isTrue);
    });

    test(
      'returns a timeout failure when the request exceeds the configured timeout',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);

        server.listen((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'data': {'late': true}}));
          await request.response.close();
        });

        final result = await graphqlClient<Object?>(
          config: ServiceClientConfig(
            serviceId: 'slow-graphql',
            baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
            redactedSummary: 'slow-graphql@local',
            timeout: const Duration(milliseconds: 20),
          ),
          request: const GraphqlRequest(
            operationId: 'users.timeout',
            document: 'query Slow { slow }',
          ),
        );

        expect(result.isFailure, isTrue);
        expect(result.failure.category, ServiceFailureCategory.timeout);
        expect(result.failure.code, 'timeout');
        expect(result.failure.retryable, isTrue);
      },
    );

    test('keeps transport failures separate from GraphQL envelopes', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        request.response.statusCode = HttpStatus.unauthorized;
        request.response.write('missing token');
        await request.response.close();
      });

      final result = await graphqlClient<Object?>(
        config: ServiceClientConfig(
          serviceId: 'users-graphql',
          baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
          redactedSummary: 'users-graphql@local',
        ),
        request: const GraphqlRequest(
          operationId: 'users.transport',
          document: 'query Viewer { viewer { id } }',
        ),
      );

      expect(result.isFailure, isTrue);
      expect(result.failure.category, ServiceFailureCategory.auth);
      expect(result.failure.code, 'unauthorized');
      expect(result.failure.statusCode, HttpStatus.unauthorized);
    });

    test('rejects mutation documents because the client is query-only in v1', () async {
      final result = await graphqlClient<Object?>(
        config: ServiceClientConfig(
          serviceId: 'users-graphql',
          baseUrl: Uri.parse('https://example.test'),
          redactedSummary: 'users-graphql@example',
        ),
        request: const GraphqlRequest(
          operationId: 'users.mutation',
          document: 'mutation UpdateUser { updateUser(id: 1) { id } }',
        ),
      );

      expect(result.isFailure, isTrue);
      expect(result.failure.category, ServiceFailureCategory.graphql);
      expect(result.failure.code, 'mutation_not_supported');
    });
  });

  group('GraphqlClient', () {
    test('describes its config and closes cleanly', () async {
      final client = GraphqlClient(
        ServiceClientConfig(
          serviceId: 'users-graphql',
          baseUrl: Uri.parse('https://example.test'),
          redactedSummary: 'users-graphql@example',
        ),
      );

      expect(client.describe().serviceId, 'users-graphql');
  expect(client.describe().transportId, 'graphql');

      final closed = await client.close();
      expect(closed.isSuccess, isTrue);
    });
  });
}