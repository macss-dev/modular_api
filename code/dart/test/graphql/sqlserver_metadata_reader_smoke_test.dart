import 'package:modular_api/src/graphql/sqlserver/physical_model.dart';
import 'package:modular_api/src/graphql/sqlserver/sql_server_connection_settings.dart';
import 'package:modular_api/src/graphql/sqlserver/sql_server_metadata_reader.dart';
import 'package:test/test.dart';

void main() {
  group('SqlServerMetadataReader smoke', () {
    test(
      'returns table columns with normalized native types, primary keys, and foreign keys',
      () async {
        final catalog = await _introspectStage1Fixture();

        final customer = catalog.objects.firstWhere(
          (object) => object.id == 'sales.Customer',
        );
        expect(customer.kind, PhysicalObjectKind.table);
        expect(customer.identityFields, const <String>['CustomerId']);
        expect(
          _fieldSnapshot(customer),
          equals(<Map<String, Object?>>[
            {
              'column': 'CustomerId',
              'nativeType': 'int',
              'nullable': false,
            },
            {
              'column': 'CustomerCode',
              'nativeType': 'nvarchar(20)',
              'nullable': false,
            },
            {
              'column': 'FullName',
              'nativeType': 'nvarchar(120)',
              'nullable': false,
            },
            {
              'column': 'CreatedAt',
              'nativeType': 'datetime2(7)',
              'nullable': false,
            },
            {
              'column': 'IsActive',
              'nativeType': 'bit',
              'nullable': false,
            },
          ]),
        );

        final order = catalog.objects.firstWhere(
          (object) => object.id == 'sales.Order',
        );
        expect(
          _fieldSnapshot(order),
          equals(<Map<String, Object?>>[
            {
              'column': 'OrderId',
              'nativeType': 'uniqueidentifier',
              'nullable': false,
            },
            {
              'column': 'CustomerId',
              'nativeType': 'int',
              'nullable': false,
            },
            {
              'column': 'TotalAmount',
              'nativeType': 'decimal(18,2)',
              'nullable': false,
            },
            {
              'column': 'Notes',
              'nativeType': 'nvarchar(200)',
              'nullable': true,
            },
            {
              'column': 'CreatedAt',
              'nativeType': 'datetime2(7)',
              'nullable': false,
            },
          ]),
        );
        expect(order.relations, hasLength(1));
        final relation = order.relations.single;
        expect(relation.name, 'FK_Order_Customer');
        expect(relation.targetObjectId, 'sales.Customer');
        expect(relation.sourceFields, const <String>['CustomerId']);
        expect(relation.targetFields, const <String>['CustomerId']);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'returns view columns with projected native types and nullability from real metadata',
      () async {
        final catalog = await _introspectStage1Fixture();

        final summary = catalog.objects.firstWhere(
          (object) => object.id == 'sales.vw_OrderSummary',
        );
        expect(summary.kind, PhysicalObjectKind.view);
        expect(
          _fieldSnapshot(summary),
          equals(<Map<String, Object?>>[
            {
              'column': 'OrderId',
              'nativeType': 'uniqueidentifier',
              'nullable': false,
            },
            {
              'column': 'CustomerId',
              'nativeType': 'int',
              'nullable': false,
            },
            {
              'column': 'CustomerCode',
              'nativeType': 'nvarchar(20)',
              'nullable': false,
            },
            {
              'column': 'FullName',
              'nativeType': 'nvarchar(120)',
              'nullable': false,
            },
            {
              'column': 'TotalAmount',
              'nativeType': 'decimal(18,2)',
              'nullable': false,
            },
            {
              'column': 'HasNotes',
              'nativeType': 'bit',
              'nullable': true,
            },
            {
              'column': 'CreatedAt',
              'nativeType': 'datetime2(7)',
              'nullable': false,
            },
          ]),
        );
        expect(summary.identityFields, isEmpty);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'is stable across repeated introspection of the same prepared database state',
      () async {
        final first = await _introspectStage1Fixture();
        final second = await _introspectStage1Fixture();

        expect(_catalogSnapshot(first), equals(_catalogSnapshot(second)));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'keeps logical object identity without requiring file-path provenance',
      () async {
        final catalog = await _introspectStage1Fixture();
        final customer = catalog.objects.firstWhere(
          (object) => object.id == 'sales.Customer',
        );

        expect(customer.schemaName, 'sales');
        expect(customer.objectName, 'Customer');
        expect(customer.id, 'sales.Customer');
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}

Future<PhysicalCatalog> _introspectStage1Fixture() {
  final reader = SqlServerMetadataReader(
    connection: SqlServerConnectionSettings.fromEnvironment(),
  );

  return reader.introspect(schemaNames: const {'sales'});
}

List<Map<String, Object?>> _fieldSnapshot(PhysicalObject object) {
  return object.fields
      .map(
        (field) => <String, Object?>{
          'column': field.column,
          'nativeType': field.nativeType,
          'nullable': field.nullable,
        },
      )
      .toList(growable: false);
}

Map<String, Object?> _catalogSnapshot(PhysicalCatalog catalog) {
  return <String, Object?>{
    'objects': catalog.objects
        .map(
          (object) => <String, Object?>{
            'id': object.id,
            'kind': object.kind.name,
            'schemaName': object.schemaName,
            'objectName': object.objectName,
            'identityFields': object.identityFields,
            'fields': _fieldSnapshot(object),
            'relations': object.relations
                .map(
                  (relation) => <String, Object?>{
                    'name': relation.name,
                    'sourceObjectId': relation.sourceObjectId,
                    'targetObjectId': relation.targetObjectId,
                    'sourceFields': relation.sourceFields,
                    'targetFields': relation.targetFields,
                  },
                )
                .toList(growable: false),
          },
        )
        .toList(growable: false),
  };
}