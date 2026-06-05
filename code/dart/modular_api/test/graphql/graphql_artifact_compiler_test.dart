import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:modular_api/modular_api.dart';
import 'package:modular_api/src/core/modular_api.dart' show apiRegistry;
import 'package:test/test.dart';

void main() {
  group('GraphQL artifact compiler', () {
    late Directory outputDir;

    setUp(() async {
      outputDir = await Directory.systemTemp.createTemp('graphql-artifacts-');
    });

    tearDown(() async {
      apiRegistry.routes.clear();
      if (await outputDir.exists()) {
        await outputDir.delete(recursive: true);
      }
    });

    test('compile mode emits catalog.json catalog.lock diagnostics.json and schema.graphql', () async {
      final compiler = GraphqlArtifactCompiler(
        catalogFactory: () async => _catalogOrdered(),
      );

      final bundle = await compiler.writeToDirectory(outputDir.path);

      expect(bundle.catalogJson, isNotEmpty);
      expect(bundle.catalogLockJson, isNotEmpty);
      expect(bundle.diagnosticsJson, isNotEmpty);
      expect(bundle.schemaGraphql, isNotEmpty);
      expect(await File(_artifactPath(outputDir, 'catalog.json')).exists(), isTrue);
      expect(await File(_artifactPath(outputDir, 'catalog.lock')).exists(), isTrue);
      expect(await File(_artifactPath(outputDir, 'diagnostics.json')).exists(), isTrue);
      expect(await File(_artifactPath(outputDir, 'schema.graphql')).exists(), isTrue);
    });

    test('emitted artifacts are byte stable for identical inputs', () async {
      final leftDir = await Directory.systemTemp.createTemp('graphql-artifacts-left-');
      final rightDir = await Directory.systemTemp.createTemp('graphql-artifacts-right-');

      addTearDown(() async {
        if (await leftDir.exists()) {
          await leftDir.delete(recursive: true);
        }
        if (await rightDir.exists()) {
          await rightDir.delete(recursive: true);
        }
      });

      final leftCompiler = GraphqlArtifactCompiler(
        catalogFactory: () async => _catalogOrdered(),
      );
      final rightCompiler = GraphqlArtifactCompiler(
        catalogFactory: () async => _catalogOrdered(),
      );

      await leftCompiler.writeToDirectory(leftDir.path);
      await rightCompiler.writeToDirectory(rightDir.path);

      expect(
        await File(_artifactPath(leftDir, 'catalog.json')).readAsString(),
        await File(_artifactPath(rightDir, 'catalog.json')).readAsString(),
      );
      expect(
        await File(_artifactPath(leftDir, 'catalog.lock')).readAsString(),
        await File(_artifactPath(rightDir, 'catalog.lock')).readAsString(),
      );
      expect(
        await File(_artifactPath(leftDir, 'diagnostics.json')).readAsString(),
        await File(_artifactPath(rightDir, 'diagnostics.json')).readAsString(),
      );
      expect(
        await File(_artifactPath(leftDir, 'schema.graphql')).readAsString(),
        await File(_artifactPath(rightDir, 'schema.graphql')).readAsString(),
      );
    });

    test('catalog and diagnostics artifacts are independent of source discovery order', () async {
      final leftDir = await Directory.systemTemp.createTemp('graphql-artifacts-ordered-');
      final rightDir = await Directory.systemTemp.createTemp('graphql-artifacts-reversed-');

      addTearDown(() async {
        if (await leftDir.exists()) {
          await leftDir.delete(recursive: true);
        }
        if (await rightDir.exists()) {
          await rightDir.delete(recursive: true);
        }
      });

      await GraphqlArtifactCompiler(
        catalogFactory: () async => _catalogOrdered(),
      ).writeToDirectory(leftDir.path);
      await GraphqlArtifactCompiler(
        catalogFactory: () async => _catalogDiscoveredOutOfOrder(),
      ).writeToDirectory(rightDir.path);

      expect(
        await File(_artifactPath(leftDir, 'catalog.json')).readAsString(),
        await File(_artifactPath(rightDir, 'catalog.json')).readAsString(),
      );
      expect(
        await File(_artifactPath(leftDir, 'diagnostics.json')).readAsString(),
        await File(_artifactPath(rightDir, 'diagnostics.json')).readAsString(),
      );
    });

    test('authoritative artifacts omit volatile execution time data and lock includes sourceDigest', () async {
      await GraphqlArtifactCompiler(
        catalogFactory: () async => _catalogOrdered(),
      ).writeToDirectory(outputDir.path);

      final catalogJson = await File(_artifactPath(outputDir, 'catalog.json')).readAsString();
      final catalogLockJson = await File(_artifactPath(outputDir, 'catalog.lock')).readAsString();
      final diagnosticsJson = await File(_artifactPath(outputDir, 'diagnostics.json')).readAsString();

      expect(catalogJson, isNot(contains('generatedAt')));
      expect(catalogLockJson, isNot(contains('generatedAt')));
      expect(diagnosticsJson, isNot(contains('generatedAt')));

      final lock = jsonDecode(catalogLockJson) as Map<String, Object?>;
      expect(lock['catalogVersion'], '1.0.0');
      expect(lock['sourceDigest'], 'digest-a');
      expect(lock['providerVersion'], '0.4.7-test');
    });

    test('runtime fast path loads valid prebuilt artifacts successfully', () async {
      await GraphqlArtifactCompiler(
        catalogFactory: () async => _catalogOrdered(),
      ).writeToDirectory(outputDir.path);

      final api = ModularApi(
        basePath: '/api',
        title: 'GraphQL Artifact API',
        version: '1.0.0',
        graphql: GraphqlOptions(
          artifactDirectory: outputDir.path,
          sourceDigestFactory: () async => 'digest-a',
          catalogFactory: () async => throw StateError('catalogFactory should not run on fast path'),
          executor: const _NoopExecutor(),
        ),
      );

      final server = await api.serve(port: 0);
      addTearDown(() => server.close(force: true));

      final response = await http.post(
        Uri.parse('http://localhost:${server.port}/api/graphql'),
        headers: const <String, String>{'content-type': 'application/json'},
        body: jsonEncode(<String, Object?>{
          'query': '{ customerRecordList { items { customerId } } }',
        }),
      );

      expect(response.statusCode, 200);
      expect(
        jsonDecode(response.body),
        equals(<String, Object?>{
          'data': <String, Object?>{
            'customerRecordList': <String, Object?>{'items': <Object?>[]},
          },
        }),
      );
    });

    test('drift between normalized inputs and catalog.lock is detected and falls back to source compilation', () async {
      await GraphqlArtifactCompiler(
        catalogFactory: () async => _catalogOrdered(),
      ).writeToDirectory(outputDir.path);

      var sourceCompilations = 0;
      final api = ModularApi(
        basePath: '/api',
        title: 'GraphQL Artifact API',
        version: '1.0.0',
        graphql: GraphqlOptions(
          artifactDirectory: outputDir.path,
          sourceDigestFactory: () async => 'digest-b',
          catalogFactory: () async {
            sourceCompilations += 1;
            return _catalogOrdered(sourceDigest: 'digest-b');
          },
          executor: const _NoopExecutor(),
        ),
      );

      final server = await api.serve(port: 0);
      addTearDown(() => server.close(force: true));

      expect(sourceCompilations, 1);
    });
  });
}

String _artifactPath(Directory directory, String fileName) =>
    '${directory.path}${Platform.pathSeparator}$fileName';

GraphqlCatalog _catalogOrdered({String sourceDigest = 'digest-a'}) {
  return GraphqlCatalog(
    catalogVersion: '1.0.0',
    provider: const GraphqlCatalogProvider(
      kind: 'sql',
      engine: 'sqlserver',
      providerVersion: '0.4.7-test',
    ),
    build: GraphqlCatalogBuild(
      mode: GraphqlCatalogBuildMode.compile,
      sourceRoot: 'db/src',
      sourceDigest: sourceDigest,
    ),
    objects: <GraphqlPublishedObject>[
      _customerObject(),
      _orderObject(),
    ],
    diagnostics: const <GraphqlCatalogDiagnostic>[
      GraphqlCatalogDiagnostic(
        severity: GraphqlCatalogDiagnosticSeverity.warning,
        code: 'alpha_warning',
        message: 'alpha',
      ),
      GraphqlCatalogDiagnostic(
        severity: GraphqlCatalogDiagnosticSeverity.info,
        code: 'beta_info',
        message: 'beta',
      ),
    ],
  );
}

GraphqlCatalog _catalogDiscoveredOutOfOrder() {
  return GraphqlCatalog(
    catalogVersion: '1.0.0',
    provider: const GraphqlCatalogProvider(
      kind: 'sql',
      engine: 'sqlserver',
      providerVersion: '0.4.7-test',
    ),
    build: const GraphqlCatalogBuild(
      mode: GraphqlCatalogBuildMode.compile,
      sourceRoot: 'db/src',
      sourceDigest: 'digest-a',
    ),
    objects: <GraphqlPublishedObject>[
      _orderObject(),
      _customerObject(),
    ],
    diagnostics: const <GraphqlCatalogDiagnostic>[
      GraphqlCatalogDiagnostic(
        severity: GraphqlCatalogDiagnosticSeverity.info,
        code: 'beta_info',
        message: 'beta',
      ),
      GraphqlCatalogDiagnostic(
        severity: GraphqlCatalogDiagnosticSeverity.warning,
        code: 'alpha_warning',
        message: 'alpha',
      ),
    ],
  );
}

GraphqlPublishedObject _customerObject() {
  return const GraphqlPublishedObject(
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
  );
}

GraphqlPublishedObject _orderObject() {
  return const GraphqlPublishedObject(
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
  );
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