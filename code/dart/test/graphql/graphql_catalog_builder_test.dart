import 'package:modular_api/src/graphql/catalog/graphql_catalog_builder.dart';
import 'package:modular_api/src/graphql/metadata/graphql_metadata_parser.dart';
import 'package:modular_api/src/graphql/sqlserver/physical_model.dart';
import 'package:test/test.dart';

void main() {
  group('GraphqlCatalogNaming', () {
    test('tokenizes separators casing acronyms and digits deterministically', () {
      expect(GraphqlCatalogNaming.typeNameForObjectName('vw_Retiro'), 'VwRetiro');
      expect(GraphqlCatalogNaming.typeNameForObjectName('retiro-evento'), 'RetiroEvento');
      expect(GraphqlCatalogNaming.typeNameForObjectName('retiro.evento final'), 'RetiroEventoFinal');
      expect(GraphqlCatalogNaming.publicFieldNameForColumn('URL_ARCHIVO'), 'urlArchivo');
      expect(GraphqlCatalogNaming.publicFieldNameForColumn('FechaIDCliente'), 'fechaIdCliente');
      expect(GraphqlCatalogNaming.publicFieldNameForColumn('cliente#maestro'), 'clienteMaestro');
      expect(GraphqlCatalogNaming.typeNameForObjectName('cliente2Detalle'), 'Cliente2Detalle');
    });
  });

  group('GraphqlCatalogBuilder', () {
    test('builds a governed catalog with deterministic names, identities, limits, and ordering', () {
      final catalog = _builder().build(
        physicalCatalog: _physicalCatalog(),
        metadata: _metadata(),
      );

      expect(catalog.catalogVersion, '1.0.0');
      expect(catalog.provider.kind, 'sql');
      expect(catalog.provider.engine, 'sqlserver');
      expect(catalog.build.mode, GraphqlCatalogBuildMode.runtime);
      expect(catalog.objects.map((object) => object.id).toList(growable: false), equals(const <String>[
        'sales.Customer',
        'sales.EventLog',
        'sales.Order',
        'sales.vw_OrderSummary',
      ]));

      final customer = catalog.objects.firstWhere((object) => object.id == 'sales.Customer');
      expect(customer.graphql.typeName, 'CustomerRecord');
      expect(customer.graphql.itemField, 'customerRecord');
      expect(customer.graphql.collectionField, 'customerRecordList');
      expect(customer.identity.mode, GraphqlCatalogIdentityMode.single);
      expect(customer.identity.origin, GraphqlCatalogOrigin.annotated);
      expect(customer.identity.fields, const <String>['CustomerId']);
      expect(customer.fields.map((field) => field.publicName).toList(growable: false), equals(const <String>[
        'customerCode',
        'customerId',
        'urlArchivo',
      ]));
      expect(customer.capabilities.item, isTrue);
      expect(customer.capabilities.collection, isTrue);
      expect(customer.capabilities.filter, isTrue);
      expect(customer.capabilities.sort, isTrue);
      expect(customer.capabilities.pagination.defaultLimit, 25);
      expect(customer.capabilities.pagination.maxLimit, 100);

      final eventLog = catalog.objects.firstWhere((object) => object.id == 'sales.EventLog');
      expect(eventLog.identity.mode, GraphqlCatalogIdentityMode.none);
      expect(eventLog.graphql.itemField, isNull);
      expect(eventLog.capabilities.item, isFalse);
      expect(eventLog.capabilities.collection, isTrue);
      expect(eventLog.capabilities.pagination.defaultLimit, 50);
      expect(eventLog.capabilities.pagination.maxLimit, 200);

      final summary = catalog.objects.firstWhere((object) => object.id == 'sales.vw_OrderSummary');
      expect(summary.graphql.typeName, 'OrderSummary');
      expect(summary.graphql.itemField, 'orderSummary');
      expect(summary.graphql.collectionField, 'orderSummaryList');
      expect(summary.identity.mode, GraphqlCatalogIdentityMode.single);
      expect(summary.identity.origin, GraphqlCatalogOrigin.annotated);
      expect(summary.identity.fields, const <String>['OrderId']);
      expect(summary.relations, hasLength(1));
      expect(summary.relations.single.name, 'customer');
      expect(summary.relations.single.cardinality, GraphqlCatalogRelationCardinality.one);
      expect(summary.relations.single.target, 'sales.Customer');
      expect(summary.relations.single.sourceFields, const <String>['CustomerId']);
      expect(summary.relations.single.targetFields, const <String>['CustomerId']);
      expect(summary.relations.single.origin, GraphqlCatalogOrigin.annotated);

      expect(catalog.diagnostics, isEmpty);
      expect(catalog.build.sourceDigest, isNotEmpty);
    });

    test('emits duplicate_public_name when two fields derive the same public name', () {
      final catalog = _builder().build(
        physicalCatalog: const PhysicalCatalog(
          objects: <PhysicalObject>[
            PhysicalObject(
              id: 'sales.DuplicateNames',
              kind: PhysicalObjectKind.table,
              schemaName: 'sales',
              objectName: 'DuplicateNames',
              identityFields: <String>['customer_id'],
              fields: <PhysicalField>[
                PhysicalField(column: 'customer_id', nativeType: 'int', nullable: false),
                PhysicalField(column: 'customer.id', nativeType: 'nvarchar(50)', nullable: false),
              ],
              relations: <PhysicalRelationSeed>[],
            ),
          ],
        ),
        metadata: const GraphqlMetadataFile(
          version: 1,
          objects: <String, GraphqlObjectMetadata>{
            'sales.DuplicateNames': GraphqlObjectMetadata(publish: true),
          },
        ),
      );

      expect(catalog.diagnostics, hasLength(1));
      expect(catalog.diagnostics.single.code, 'duplicate_public_name');
      expect(catalog.diagnostics.single.objectId, 'sales.DuplicateNames');
      expect(catalog.diagnostics.single.field, 'customerId');
    });

    test('emits view_missing_identity when a published view does not declare usable identity', () {
      final catalog = _builder().build(
        physicalCatalog: const PhysicalCatalog(
          objects: <PhysicalObject>[
            PhysicalObject(
              id: 'sales.vw_NoIdentity',
              kind: PhysicalObjectKind.view,
              schemaName: 'sales',
              objectName: 'vw_NoIdentity',
              identityFields: <String>[],
              fields: <PhysicalField>[
                PhysicalField(column: 'OrderId', nativeType: 'int', nullable: false),
              ],
              relations: <PhysicalRelationSeed>[],
            ),
          ],
        ),
        metadata: const GraphqlMetadataFile(
          version: 1,
          objects: <String, GraphqlObjectMetadata>{
            'sales.vw_NoIdentity': GraphqlObjectMetadata(publish: true),
          },
        ),
      );

      final summary = catalog.objects.single;
      expect(summary.identity.mode, GraphqlCatalogIdentityMode.none);
      expect(summary.graphql.itemField, isNull);
      expect(summary.capabilities.item, isFalse);
      expect(catalog.diagnostics, hasLength(1));
      expect(catalog.diagnostics.single.code, 'view_missing_identity');
      expect(catalog.diagnostics.single.objectId, 'sales.vw_NoIdentity');
    });

    test('preserves semantic order for composite identity and relation key fields', () {
      final catalog = _builder().build(
        physicalCatalog: const PhysicalCatalog(
          objects: <PhysicalObject>[
            PhysicalObject(
              id: 'sales.CompositeTarget',
              kind: PhysicalObjectKind.table,
              schemaName: 'sales',
              objectName: 'CompositeTarget',
              identityFields: <String>['CountryCode', 'CustomerCode'],
              fields: <PhysicalField>[
                PhysicalField(column: 'CountryCode', nativeType: 'nvarchar(2)', nullable: false),
                PhysicalField(column: 'CustomerCode', nativeType: 'nvarchar(50)', nullable: false),
              ],
              relations: <PhysicalRelationSeed>[],
            ),
            PhysicalObject(
              id: 'sales.vw_CompositeSource',
              kind: PhysicalObjectKind.view,
              schemaName: 'sales',
              objectName: 'vw_CompositeSource',
              identityFields: <String>[],
              fields: <PhysicalField>[
                PhysicalField(column: 'KeyB', nativeType: 'int', nullable: false),
                PhysicalField(column: 'KeyA', nativeType: 'int', nullable: false),
                PhysicalField(column: 'CountryCode', nativeType: 'nvarchar(2)', nullable: false),
                PhysicalField(column: 'CustomerCode', nativeType: 'nvarchar(50)', nullable: false),
              ],
              relations: <PhysicalRelationSeed>[],
            ),
          ],
        ),
        metadata: const GraphqlMetadataFile(
          version: 1,
          objects: <String, GraphqlObjectMetadata>{
            'sales.CompositeTarget': GraphqlObjectMetadata(publish: true),
            'sales.vw_CompositeSource': GraphqlObjectMetadata(
              publish: true,
              key: <String>['KeyB', 'KeyA'],
              relations: <GraphqlRelationMetadata>[
                GraphqlRelationMetadata(
                  name: 'target',
                  cardinality: 'to-one',
                  target: 'sales.CompositeTarget',
                  via: <String>['CountryCode', 'CustomerCode'],
                ),
              ],
            ),
          },
        ),
      );

      final source = catalog.objects.firstWhere((object) => object.id == 'sales.vw_CompositeSource');
      expect(source.identity.fields, const <String>['KeyB', 'KeyA']);
      expect(source.relations.single.sourceFields, const <String>['CountryCode', 'CustomerCode']);
      expect(source.relations.single.targetFields, const <String>['CountryCode', 'CustomerCode']);
      expect(catalog.diagnostics, isEmpty);
    });

    test('keeps sourceDigest stable across semantically identical input order and changes it on relevant input changes', () {
      final first = _builder().build(
        physicalCatalog: _physicalCatalog(),
        metadata: _metadata(),
      );
      final second = _builder().build(
        physicalCatalog: PhysicalCatalog(objects: _physicalCatalog().objects.reversed.toList(growable: false)),
        metadata: GraphqlMetadataFile(
          version: _metadata().version,
          defaultsLimit: _metadata().defaultsLimit,
          objects: Map<String, GraphqlObjectMetadata>.fromEntries(
            _metadata().objects.entries.toList(growable: false).reversed,
          ),
        ),
      );
      final changed = _builder().build(
        physicalCatalog: _physicalCatalog(),
        metadata: GraphqlMetadataFile(
          version: _metadata().version,
          defaultsLimit: _metadata().defaultsLimit,
          objects: <String, GraphqlObjectMetadata>{
            for (final entry in _metadata().objects.entries)
              entry.key: entry.key == 'sales.Customer'
                  ? GraphqlObjectMetadata(
                      publish: entry.value.publish,
                      name: 'CustomerRenamed',
                      key: entry.value.key,
                      fields: entry.value.fields,
                      relations: entry.value.relations,
                      limit: entry.value.limit,
                    )
                  : entry.value,
          },
        ),
      );

      expect(first.build.sourceDigest, equals(second.build.sourceDigest));
      expect(first.build.sourceDigest, isNot(equals(changed.build.sourceDigest)));
    });
  });
}

GraphqlCatalogBuilder _builder() {
  return const GraphqlCatalogBuilder(
    providerVersion: '0.4.7-test',
    sourceRoot: 'db/src',
    buildMode: GraphqlCatalogBuildMode.runtime,
    engine: 'sqlserver',
  );
}

GraphqlMetadataFile _metadata() {
  return const GraphqlMetadataFile(
    version: 1,
    defaultsLimit: GraphqlMetadataLimit(defaultValue: 50, maxValue: 200),
    objects: <String, GraphqlObjectMetadata>{
      'sales.Customer': GraphqlObjectMetadata(
        publish: true,
        name: 'CustomerRecord',
        key: <String>['CustomerId'],
        fields: <String, GraphqlFieldMetadata>{
          'CustomerCode': GraphqlFieldMetadata(name: 'customerCode'),
        },
        limit: GraphqlMetadataLimit(defaultValue: 25, maxValue: 100),
      ),
      'sales.EventLog': GraphqlObjectMetadata(
        publish: true,
      ),
      'sales.Order': GraphqlObjectMetadata(
        publish: true,
      ),
      'sales.vw_OrderSummary': GraphqlObjectMetadata(
        publish: true,
        name: 'OrderSummary',
        key: <String>['OrderId'],
        relations: <GraphqlRelationMetadata>[
          GraphqlRelationMetadata(
            name: 'customer',
            cardinality: 'to-one',
            target: 'sales.Customer',
            via: <String>['CustomerId'],
          ),
        ],
      ),
    },
  );
}

PhysicalCatalog _physicalCatalog() {
  return const PhysicalCatalog(
    objects: <PhysicalObject>[
      PhysicalObject(
        id: 'sales.Order',
        kind: PhysicalObjectKind.table,
        schemaName: 'sales',
        objectName: 'Order',
        identityFields: <String>['OrderId'],
        fields: <PhysicalField>[
          PhysicalField(column: 'OrderId', nativeType: 'int', nullable: false),
          PhysicalField(column: 'CustomerId', nativeType: 'int', nullable: false),
          PhysicalField(column: 'TotalAmount', nativeType: 'decimal(18,2)', nullable: false),
        ],
        relations: <PhysicalRelationSeed>[
          PhysicalRelationSeed(
            name: 'Customer',
            sourceObjectId: 'sales.Order',
            targetObjectId: 'sales.Customer',
            sourceFields: <String>['CustomerId'],
            targetFields: <String>['CustomerId'],
          ),
        ],
      ),
      PhysicalObject(
        id: 'sales.Customer',
        kind: PhysicalObjectKind.table,
        schemaName: 'sales',
        objectName: 'Customer',
        identityFields: <String>['CustomerId'],
        fields: <PhysicalField>[
          PhysicalField(column: 'CustomerId', nativeType: 'int', nullable: false),
          PhysicalField(column: 'CustomerCode', nativeType: 'nvarchar(50)', nullable: false),
          PhysicalField(column: 'URLArchivo', nativeType: 'nvarchar(255)', nullable: true),
        ],
        relations: <PhysicalRelationSeed>[],
      ),
      PhysicalObject(
        id: 'sales.vw_OrderSummary',
        kind: PhysicalObjectKind.view,
        schemaName: 'sales',
        objectName: 'vw_OrderSummary',
        identityFields: <String>[],
        fields: <PhysicalField>[
          PhysicalField(column: 'OrderId', nativeType: 'int', nullable: false),
          PhysicalField(column: 'CustomerId', nativeType: 'int', nullable: false),
          PhysicalField(column: 'HasNotes', nativeType: 'bit', nullable: true),
        ],
        relations: <PhysicalRelationSeed>[],
      ),
      PhysicalObject(
        id: 'sales.EventLog',
        kind: PhysicalObjectKind.table,
        schemaName: 'sales',
        objectName: 'EventLog',
        identityFields: <String>[],
        fields: <PhysicalField>[
          PhysicalField(column: 'CreatedAt', nativeType: 'datetime2', nullable: false),
          PhysicalField(column: 'PayloadJson', nativeType: 'nvarchar(max)', nullable: true),
        ],
        relations: <PhysicalRelationSeed>[],
      ),
    ],
  );
}