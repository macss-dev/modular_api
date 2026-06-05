import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';

void main() {
  test('public graphql surface exposes metadata, sqlserver and catalog building primitives', () {
    const parser = GraphqlMetadataParser();
    const physicalCatalog = PhysicalCatalog(
      objects: <PhysicalObject>[
        PhysicalObject(
          id: 'sales.Customer',
          kind: PhysicalObjectKind.table,
          schemaName: 'sales',
          objectName: 'Customer',
          identityFields: <String>['CustomerId'],
          fields: <PhysicalField>[
            PhysicalField(
              column: 'CustomerId',
              nativeType: 'int',
              nullable: false,
            ),
          ],
          relations: <PhysicalRelationSeed>[],
        ),
      ],
    );

    final parsed = parser.parse(
      rawJsonc: '''
{
  version: 1,
  objects: {
    "sales.Customer": {
      publish: true,
    },
  },
}
''',
      physicalCatalog: physicalCatalog,
    );

    expect(parsed.metadata, isNotNull);
    expect(parsed.diagnostics.where((d) => d.severity == GraphqlMetadataSeverity.error), isEmpty);

    final catalog = const GraphqlCatalogBuilder(
      providerVersion: '0.4.7-test',
      sourceRoot: 'code/db',
      buildMode: GraphqlCatalogBuildMode.compile,
      engine: 'sqlserver',
    ).build(
      physicalCatalog: physicalCatalog,
      metadata: parsed.metadata!,
    );

    expect(catalog.provider.engine, 'sqlserver');
    expect(catalog.objects.single.id, 'sales.Customer');

    final connection = SqlServerConnectionSettings.fromEnvironment(
      environment: const {'MODULAR_API_SQLSERVER_HOST': 'db.local'},
    );
    final reader = SqlServerMetadataReader(connection: connection);

    expect(connection.host, 'db.local');
    expect(reader, isA<SqlServerMetadataReader>());
  });
}