import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:modular_api/modular_api.dart';
import 'package:modular_api/src/core/modular_api.dart' show apiRegistry;
import 'package:test/test.dart';

void main() {
  group('GraphQL runtime integration', () {
    HttpServer? server;
    late String baseUrl;

    tearDown(() async {
      if (server != null) {
        await server!.close(force: true);
      }
      apiRegistry.routes.clear();
    });

    test('health reports graphql disabled and endpoint is absent by default', () async {
      final api = ModularApi(
        basePath: '/api',
        title: 'GraphQL Test API',
        version: '1.0.0',
      );

      server = await api.serve(port: 0);
      baseUrl = 'http://localhost:${server!.port}';

      final graphqlResponse = await http.post(
        Uri.parse('$baseUrl/api/graphql'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(<String, Object?>{'query': '{ __typename }'}),
      );
      expect(graphqlResponse.statusCode, 404);

      final healthResponse = await http.get(Uri.parse('$baseUrl/api/health'));
      expect(healthResponse.statusCode, 200);
      final healthJson = jsonDecode(healthResponse.body) as Map<String, Object?>;
      final checks = healthJson['checks'] as Map<String, Object?>;
      final graphqlCheck = checks['graphql'] as Map<String, Object?>;
      expect(graphqlCheck['status'], 'pass');
      expect(graphqlCheck['output'], 'disabled');
    });

    test('GraphqlOptions defaults introspection false maxDepth 8 and maxComplexity 500', () {
      final options = GraphqlOptions(
        catalogFactory: () async => _catalog(),
        executor: const _NoopExecutor(),
      );

      expect(options.introspectionEnabled, isFalse);
      expect(options.maxDepth, 8);
      expect(options.maxComplexity, 500);
      expect(options.executionCapabilityId, isNull);
    });

    test('graphql endpoint mounts under basePath and health reports ready when startup succeeds', () async {
      final api = ModularApi(
        basePath: '/api',
        title: 'GraphQL Test API',
        version: '1.0.0',
        graphql: GraphqlOptions(
          catalogFactory: () async => _catalog(),
          executionCapabilityId: 'modular_api.sql.read_executor',
        ),
      )..plugin(
          _ExecutorCapabilityPlugin(
            id: 'acme.sql.read-executor',
            capabilityId: 'modular_api.sql.read_executor',
            executor: const _NoopExecutor(),
          ),
        );

      server = await api.serve(port: 0);
      baseUrl = 'http://localhost:${server!.port}';

      final graphqlResponse = await http.post(
        Uri.parse('$baseUrl/api/graphql'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(<String, Object?>{'query': '{ __typename }'}),
      );
      expect(graphqlResponse.statusCode, 200);
      expect(
        jsonDecode(graphqlResponse.body),
        equals(const <String, Object?>{
          'data': <String, Object?>{'__typename': 'Query'},
        }),
      );

      final healthResponse = await http.get(Uri.parse('$baseUrl/api/health'));
      expect(healthResponse.statusCode, 200);
      final healthJson = jsonDecode(healthResponse.body) as Map<String, Object?>;
      final checks = healthJson['checks'] as Map<String, Object?>;
      final graphqlCheck = checks['graphql'] as Map<String, Object?>;
      expect(graphqlCheck['status'], 'pass');
      expect(graphqlCheck['output'], 'ready');
    });

    test('startup fails when catalog construction fails', () {
      final api = ModularApi(
        basePath: '/api',
        graphql: GraphqlOptions(
          catalogFactory: () async => throw StateError('introspection failed'),
          executor: const _NoopExecutor(),
        ),
      );

      expect(
        api.serve(port: 0),
        throwsA(
          isA<PluginHostError>()
              .having((error) => error.code, 'code', 'PLUGIN_VALIDATION_FAILED')
              .having((error) => error.resourceId, 'resourceId', 'graphql.catalog'),
        ),
      );
    });

    test('startup fails when executor capability is missing', () {
      final api = ModularApi(
        basePath: '/api',
        graphql: GraphqlOptions(
          catalogFactory: () async => _catalog(),
          executionCapabilityId: 'missing.sql.read_executor',
        ),
      );

      expect(
        api.serve(port: 0),
        throwsA(
          isA<PluginHostError>()
              .having((error) => error.code, 'code', 'PLUGIN_VALIDATION_FAILED')
              .having((error) => error.resourceId, 'resourceId', 'missing.sql.read_executor'),
        ),
      );
    });

    test('startup fails when schema generation fails', () {
      final api = ModularApi(
        basePath: '/api',
        graphql: GraphqlOptions(
          catalogFactory: () async => _catalog(),
          executor: const _NoopExecutor(),
          sdlFactory: (_) => 'type Query {',
        ),
      );

      expect(
        api.serve(port: 0),
        throwsA(
          isA<PluginHostError>()
              .having((error) => error.code, 'code', 'PLUGIN_VALIDATION_FAILED')
              .having((error) => error.resourceId, 'resourceId', 'graphql.schema'),
        ),
      );
    });

    test('startup fails when maxDepth is invalid', () {
      final api = ModularApi(
        basePath: '/api',
        graphql: GraphqlOptions(
          catalogFactory: () async => _catalog(),
          executor: const _NoopExecutor(),
          maxDepth: 0,
        ),
      );

      expect(
        api.serve(port: 0),
        throwsA(
          isA<PluginHostError>()
              .having((error) => error.code, 'code', 'PLUGIN_VALIDATION_FAILED')
              .having((error) => error.resourceId, 'resourceId', 'graphql.maxDepth'),
        ),
      );
    });

    test('startup fails when maxComplexity is invalid', () {
      final api = ModularApi(
        basePath: '/api',
        graphql: GraphqlOptions(
          catalogFactory: () async => _catalog(),
          executor: const _NoopExecutor(),
          maxComplexity: -1,
        ),
      );

      expect(
        api.serve(port: 0),
        throwsA(
          isA<PluginHostError>()
              .having((error) => error.code, 'code', 'PLUGIN_VALIDATION_FAILED')
              .having((error) => error.resourceId, 'resourceId', 'graphql.maxComplexity'),
        ),
      );
    });

    test('direct executor and capability id are mutually exclusive', () {
      expect(
        () => GraphqlOptions(
          catalogFactory: () async => _catalog(),
          executor: const _NoopExecutor(),
          executionCapabilityId: 'modular_api.sql.read_executor',
        ),
        throwsArgumentError,
      );
    });
  });
}

GraphqlCatalog _catalog() {
  return GraphqlCatalog(
    catalogVersion: '1.0.0',
    provider: const GraphqlCatalogProvider(
      kind: 'sql',
      engine: 'sqlserver',
      providerVersion: '0.4.7-test',
    ),
    build: const GraphqlCatalogBuild(
      mode: GraphqlCatalogBuildMode.runtime,
      sourceRoot: 'db/src',
      sourceDigest: 'test-digest',
    ),
    objects: const <GraphqlPublishedObject>[
      GraphqlPublishedObject(
        id: 'sales.Customer',
        kind: PhysicalObjectKind.table,
        readonly: true,
        source: GraphqlCatalogSource(
          schemaName: 'sales',
          objectName: 'Customer',
        ),
        graphql: GraphqlCatalogGraphqlNames(
          typeName: 'CustomerRecord',
          collectionField: 'customerRecordList',
          itemField: 'customerRecord',
        ),
        identity: GraphqlCatalogIdentity(
          mode: GraphqlCatalogIdentityMode.single,
          fields: <String>['CustomerId'],
          origin: GraphqlCatalogOrigin.inferred,
        ),
        fields: <GraphqlCatalogField>[
          GraphqlCatalogField(
            column: 'CustomerId',
            publicName: 'customerId',
            type: 'Int',
            nullable: false,
            visibility: GraphqlCatalogFieldVisibility.public,
            filterable: true,
            sortable: true,
            sensitive: false,
            origin: GraphqlCatalogOrigin.inferred,
          ),
        ],
        relations: <GraphqlCatalogRelation>[],
        capabilities: GraphqlCatalogCapabilities(
          item: true,
          collection: true,
          filter: true,
          sort: true,
          pagination: GraphqlCatalogPagination(
            mode: GraphqlCatalogPaginationMode.offset,
            defaultLimit: 25,
            maxLimit: 100,
          ),
        ),
      ),
    ],
    diagnostics: const <GraphqlCatalogDiagnostic>[],
  );
}

final class _ExecutorCapabilityPlugin implements Plugin {
  _ExecutorCapabilityPlugin({
    required this.id,
    required this.capabilityId,
    required this.executor,
  });

  final String id;
  final String capabilityId;
  final SqlReadExecutor executor;

  @override
  PluginManifest get manifest => PluginManifest(
        id: id,
        displayName: 'Executor Capability Plugin',
        version: '0.1.0',
        hostApiVersion: '>=0.1.0 <0.2.0',
      );

  @override
  void setup(PluginHost host) {
    host.exposeCapability(
      Capability<SqlReadExecutor>(
        id: capabilityId,
        version: '1.0.0',
        value: executor,
      ),
    );
  }
}

final class _NoopExecutor implements SqlReadExecutor {
  const _NoopExecutor();

  @override
  Future<void> close() async {}

  @override
  Future<RowSet> execute(SqlReadCommand command, ReadExecutionContext context) async {
    return const RowSet(rows: <Map<String, Object?>>[], rowCount: 0);
  }
}