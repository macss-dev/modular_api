import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:modular_api/modular_api.dart';
import 'package:modular_api/src/core/modular_api.dart' show apiRegistry;
import 'package:test/test.dart';

void main() {
  group('GraphQL runtime execution', () {
    HttpServer? server;
    late String baseUrl;

    tearDown(() async {
      if (server != null) {
        await server!.close(force: true);
      }
      apiRegistry.routes.clear();
    });

    test('relation resolution batches one command for many parents', () async {
      final executor = _RecordingExecutor();
      final api = _api(
        executor: executor,
      );

      server = await api.serve(port: 0);
      baseUrl = 'http://localhost:${server!.port}';

      final response = await _postQuery(
        baseUrl,
        '{ customerRecordList { items { customerId name orders { orderId customerId } } } }',
      );

      expect(response.statusCode, 200);
      expect(
        jsonDecode(response.body),
        equals(<String, Object?>{
          'data': <String, Object?>{
            'customerRecordList': <String, Object?>{
              'items': <Object?>[
                <String, Object?>{
                  'customerId': 1,
                  'name': 'Ada',
                  'orders': <Object?>[
                    <String, Object?>{'orderId': 10, 'customerId': 1},
                    <String, Object?>{'orderId': 11, 'customerId': 1},
                  ],
                },
                <String, Object?>{
                  'customerId': 2,
                  'name': 'Linus',
                  'orders': <Object?>[
                    <String, Object?>{'orderId': 20, 'customerId': 2},
                  ],
                },
              ],
            },
          },
        }),
      );

      expect(
        executor.commands.where((command) => command.purpose == SqlReadCommandPurpose.collection),
        hasLength(1),
      );
      expect(
        executor.commands.where((command) => command.purpose == SqlReadCommandPurpose.relationBatch),
        hasLength(1),
      );
    });

    test('totalCount runs only when selected', () async {
      final executor = _RecordingExecutor();
      final api = _api(executor: executor);

      server = await api.serve(port: 0);
      baseUrl = 'http://localhost:${server!.port}';

      final withoutCount = await _postQuery(
        baseUrl,
        '{ customerRecordList { items { customerId } } }',
      );
      expect(withoutCount.statusCode, 200);
      expect(
        executor.commands.where((command) => command.purpose == SqlReadCommandPurpose.count),
        isEmpty,
      );

      executor.reset();

      final withCount = await _postQuery(
        baseUrl,
        '{ customerRecordList { items { customerId } totalCount } }',
      );
      expect(withCount.statusCode, 200);
      expect(
        executor.commands.where((command) => command.purpose == SqlReadCommandPurpose.collection),
        hasLength(1),
      );
      expect(
        executor.commands.where((command) => command.purpose == SqlReadCommandPurpose.count),
        hasLength(1),
      );
      expect(
        jsonDecode(withCount.body),
        equals(<String, Object?>{
          'data': <String, Object?>{
            'customerRecordList': <String, Object?>{
              'items': <Object?>[
                <String, Object?>{'customerId': 1},
                <String, Object?>{'customerId': 2},
              ],
              'totalCount': 2,
            },
          },
        }),
      );
    });

    test('app pagination narrows catalog defaults and omitted page uses effective default', () async {
      final executor = _RecordingExecutor();
      final api = _api(
        executor: executor,
        defaultLimit: 20,
        maxLimit: 80,
      );

      server = await api.serve(port: 0);
      baseUrl = 'http://localhost:${server!.port}';

      final response = await _postQuery(
        baseUrl,
        '{ customerRecordList { items { customerId } } }',
      );

      expect(response.statusCode, 200);
      final collectionCommand = executor.commands.singleWhere(
        (command) => command.purpose == SqlReadCommandPurpose.collection,
      );
      expect(collectionCommand.parameters.map((parameter) => parameter.value).toList(), [0, 20]);
    });

    test('client page limit above effective max fails validation instead of clamping', () async {
      final executor = _RecordingExecutor();
      final api = _api(
        executor: executor,
        defaultLimit: 20,
        maxLimit: 80,
      );

      server = await api.serve(port: 0);
      baseUrl = 'http://localhost:${server!.port}';

      final response = await _postQuery(
        baseUrl,
        '{ customerRecordList(page: { limit: 90 }) { items { customerId } } }',
      );

      expect(response.statusCode, 200);
      final body = jsonDecode(response.body) as Map<String, Object?>;
      final errors = body['errors'] as List<Object?>;
      final firstError = errors.first as Map<String, Object?>;
      expect(firstError['message'], contains('effective max limit'));
      expect(executor.commands, isEmpty);
    });

    test('negative page values fail validation and offset defaults to zero', () async {
      final executor = _RecordingExecutor();
      final api = _api(executor: executor);

      server = await api.serve(port: 0);
      baseUrl = 'http://localhost:${server!.port}';

      final negativeResponse = await _postQuery(
        baseUrl,
        '{ customerRecordList(page: { limit: -1, offset: -2 }) { items { customerId } } }',
      );
      expect(negativeResponse.statusCode, 200);
      final negativeBody = jsonDecode(negativeResponse.body) as Map<String, Object?>;
      final negativeErrors = negativeBody['errors'] as List<Object?>;
      final firstError = negativeErrors.first as Map<String, Object?>;
      expect(firstError['message'], contains('must be non-negative'));
      expect(executor.commands, isEmpty);

      executor.reset();

      final offsetDefaultResponse = await _postQuery(
        baseUrl,
        '{ customerRecordList(page: { limit: 5 }) { items { customerId } } }',
      );
      expect(offsetDefaultResponse.statusCode, 200);
      final collectionCommand = executor.commands.singleWhere(
        (command) => command.purpose == SqlReadCommandPurpose.collection,
      );
      expect(collectionCommand.parameters.map((parameter) => parameter.value).toList(), [0, 5]);
    });

    test('page limit zero yields empty items and still allows totalCount', () async {
      final executor = _RecordingExecutor();
      final api = _api(executor: executor);

      server = await api.serve(port: 0);
      baseUrl = 'http://localhost:${server!.port}';

      final response = await _postQuery(
        baseUrl,
        '{ customerRecordList(page: { limit: 0 }) { items { customerId } totalCount } }',
      );

      expect(response.statusCode, 200);
      expect(
        jsonDecode(response.body),
        equals(<String, Object?>{
          'data': <String, Object?>{
            'customerRecordList': <String, Object?>{
              'items': <Object?>[],
              'totalCount': 2,
            },
          },
        }),
      );
      expect(
        executor.commands.where((command) => command.purpose == SqlReadCommandPurpose.collection),
        isEmpty,
      );
      expect(
        executor.commands.where((command) => command.purpose == SqlReadCommandPurpose.count),
        hasLength(1),
      );
    });

    test('request scoped execution context reaches executor', () async {
      final executor = _RecordingExecutor();
      final api = _api(executor: executor);

      server = await api.serve(port: 0);
      baseUrl = 'http://localhost:${server!.port}';

      final response = await _postQuery(
        baseUrl,
        '{ customerRecordList { items { customerId } } }',
        headers: const <String, String>{
          'X-Request-ID': 'req-123',
          'X-Tenant-ID': 'tenant-a',
          'X-Principal': 'user-a',
        },
      );

      expect(response.statusCode, 200);
      final context = executor.contexts.single;
      expect(context.requestId, 'req-123');
      expect(context.tenantId, 'tenant-a');
      expect(context.principal, 'user-a');
    });

    test('query depth limits are enforced', () async {
      final executor = _RecordingExecutor();
      final api = _api(
        executor: executor,
        maxDepth: 2,
        maxComplexity: 500,
      );

      server = await api.serve(port: 0);
      baseUrl = 'http://localhost:${server!.port}';

      final depthResponse = await _postQuery(
        baseUrl,
        '{ customerRecordList { items { orders { orderId } } } }',
      );
      final depthBody = jsonDecode(depthResponse.body) as Map<String, Object?>;
      final depthErrors = depthBody['errors'] as List<Object?>;
      final depthFirstError = depthErrors.first as Map<String, Object?>;
      final depthExtensions = depthFirstError['extensions'] as Map<String, Object?>;
      final depthValidation = depthExtensions['validationError'] as Map<String, Object?>;
      expect(depthValidation['code'], 'queryDepthComplexity');
      expect(executor.commands, isEmpty);

      expect(executor.commands, isEmpty);
    });

    test('query complexity limits are enforced', () async {
      final executor = _RecordingExecutor();
      final api = _api(
        executor: executor,
        maxDepth: 8,
        maxComplexity: 5,
      );

      server = await api.serve(port: 0);
      baseUrl = 'http://localhost:${server!.port}';

      final response = await _postQuery(
        baseUrl,
        '{ customerRecordList { items { customerId } } }',
      );
      final body = jsonDecode(response.body) as Map<String, Object?>;
      final errors = body['errors'] as List<Object?>;
      final firstError = errors.first as Map<String, Object?>;
      final extensions = firstError['extensions'] as Map<String, Object?>;
      final validation = extensions['validationError'] as Map<String, Object?>;
      expect(validation['code'], 'queryComplexity');
      expect(executor.commands, isEmpty);
    });

    test('introspection when enabled remains subject to the same limits', () async {
      final executor = _RecordingExecutor();
      final api = _api(
        executor: executor,
        introspectionEnabled: true,
        maxDepth: 1,
      );

      server = await api.serve(port: 0);
      baseUrl = 'http://localhost:${server!.port}';

      final response = await _postQuery(
        baseUrl,
        '{ __schema { queryType { name } } }',
      );

      expect(response.statusCode, 200);
      final body = jsonDecode(response.body) as Map<String, Object?>;
      final errors = body['errors'] as List<Object?>;
      final firstError = errors.first as Map<String, Object?>;
      final extensions = firstError['extensions'] as Map<String, Object?>;
      final validation = extensions['validationError'] as Map<String, Object?>;
      expect(validation['code'], 'queryDepthComplexity');
      expect(executor.commands, isEmpty);
    });

    test('telemetry hook captures graphql request lifecycle events', () async {
      final executor = _RecordingExecutor();
      final events = <GraphqlRequestEvent>[];
      final api = _api(
        executor: executor,
        onEvent: events.add,
      );

      server = await api.serve(port: 0);
      baseUrl = 'http://localhost:${server!.port}';

      final response = await _postQuery(
        baseUrl,
        '{ customerRecordList { items { customerId } } }',
        headers: const <String, String>{'X-Request-ID': 'req-telemetry'},
      );

      expect(response.statusCode, 200);
      expect(events, hasLength(2));
      expect(events.first.phase, GraphqlRequestPhase.started);
      expect(events.first.requestId, 'req-telemetry');
      expect(events.last.phase, GraphqlRequestPhase.completed);
      expect(events.last.requestId, 'req-telemetry');
      expect(events.last.statusCode, 200);
    });
  });
}

ModularApi _api({
  required SqlReadExecutor executor,
  int maxDepth = 8,
  int maxComplexity = 500,
  int defaultLimit = 50,
  int maxLimit = 200,
  bool introspectionEnabled = false,
  void Function(GraphqlRequestEvent event)? onEvent,
}) {
  return ModularApi(
    basePath: '/api',
    title: 'GraphQL Runtime API',
    version: '1.0.0',
    graphql: GraphqlOptions(
      catalogFactory: () async => _catalog(),
      executor: executor,
      introspectionEnabled: introspectionEnabled,
      maxDepth: maxDepth,
      maxComplexity: maxComplexity,
      defaultLimit: defaultLimit,
      maxLimit: maxLimit,
      onEvent: onEvent,
    ),
  );
}

Future<http.Response> _postQuery(
  String baseUrl,
  String query, {
  Map<String, String> headers = const <String, String>{},
}) {
  return http.post(
    Uri.parse('$baseUrl/api/graphql'),
    headers: <String, String>{
      'content-type': 'application/json',
      ...headers,
    },
    body: jsonEncode(<String, Object?>{'query': query}),
  );
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
      sourceDigest: 'execution-test-digest',
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
          GraphqlCatalogField(
            column: 'Name',
            publicName: 'name',
            type: 'String',
            nullable: false,
            visibility: GraphqlCatalogFieldVisibility.public,
            filterable: true,
            sortable: true,
            sensitive: false,
            origin: GraphqlCatalogOrigin.inferred,
          ),
        ],
        relations: <GraphqlCatalogRelation>[
          GraphqlCatalogRelation(
            name: 'orders',
            target: 'sales.Order',
            cardinality: GraphqlCatalogRelationCardinality.many,
            sourceFields: <String>['CustomerId'],
            targetFields: <String>['CustomerId'],
            origin: GraphqlCatalogOrigin.inferred,
          ),
        ],
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
      GraphqlPublishedObject(
        id: 'sales.Order',
        kind: PhysicalObjectKind.table,
        readonly: true,
        source: GraphqlCatalogSource(
          schemaName: 'sales',
          objectName: 'Order',
        ),
        graphql: GraphqlCatalogGraphqlNames(
          typeName: 'OrderRecord',
          collectionField: 'orderRecordList',
          itemField: 'orderRecord',
        ),
        identity: GraphqlCatalogIdentity(
          mode: GraphqlCatalogIdentityMode.single,
          fields: <String>['OrderId'],
          origin: GraphqlCatalogOrigin.inferred,
        ),
        fields: <GraphqlCatalogField>[
          GraphqlCatalogField(
            column: 'OrderId',
            publicName: 'orderId',
            type: 'Int',
            nullable: false,
            visibility: GraphqlCatalogFieldVisibility.public,
            filterable: true,
            sortable: true,
            sensitive: false,
            origin: GraphqlCatalogOrigin.inferred,
          ),
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

final class _RecordingExecutor implements SqlReadExecutor {
  final List<SqlReadCommand> commands = <SqlReadCommand>[];
  final List<ReadExecutionContext> contexts = <ReadExecutionContext>[];

  @override
  Future<RowSet> execute(SqlReadCommand command, ReadExecutionContext context) async {
    commands.add(command);
    contexts.add(context);

    if (command.purpose == SqlReadCommandPurpose.collection &&
        command.sql.contains('[sales].[Customer]')) {
      final offset = command.parameters[0].value as int;
      final limit = command.parameters[1].value as int;
      final rows = _customers.skip(offset).take(limit).toList(growable: false);
      return RowSet(rows: rows, rowCount: rows.length);
    }

    if (command.purpose == SqlReadCommandPurpose.count &&
        command.sql.contains('[sales].[Customer]')) {
      return const RowSet(
        rows: <Map<String, Object?>>[
          <String, Object?>{'totalCount': 2},
        ],
        rowCount: 1,
      );
    }

    if (command.purpose == SqlReadCommandPurpose.relationBatch &&
        command.sql.contains('[sales].[Order]')) {
      final parentCustomerIds = command.parameters
          .map((parameter) => parameter.value)
          .whereType<int>()
          .toSet();
      final rows = _orders
          .where((row) => parentCustomerIds.contains(row['customerId']))
          .toList(growable: false);
      return RowSet(rows: rows, rowCount: rows.length);
    }

    throw StateError('Unexpected command: ${command.purpose} ${command.sql}');
  }

  @override
  Future<void> close() async {}

  void reset() {
    commands.clear();
    contexts.clear();
  }
}

const List<Map<String, Object?>> _customers = <Map<String, Object?>>[
  <String, Object?>{'customerId': 1, 'name': 'Ada'},
  <String, Object?>{'customerId': 2, 'name': 'Linus'},
];

const List<Map<String, Object?>> _orders = <Map<String, Object?>>[
  <String, Object?>{'orderId': 10, 'customerId': 1},
  <String, Object?>{'orderId': 11, 'customerId': 1},
  <String, Object?>{'orderId': 20, 'customerId': 2},
];