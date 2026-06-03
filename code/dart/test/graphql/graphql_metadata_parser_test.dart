import 'package:modular_api/src/graphql/metadata/graphql_metadata_parser.dart';
import 'package:modular_api/src/graphql/sqlserver/physical_model.dart';
import 'package:test/test.dart';

void main() {
  group('GraphqlMetadataParser', () {
    test('parses JSONC and emits view_missing_identity for published views without key', () {
      const parser = GraphqlMetadataParser();

      final result = parser.parse(
        rawJsonc: '''
{
  // JSONC comment
  version: 1,
  objects: {
    "sales.vw_OrderSummary": {
      publish: true,
    },
  },
}
''',
        physicalCatalog: _physicalCatalog(),
      );

      expect(result.metadata, isNotNull);
      expect(result.metadata!.version, 1);
      expect(
        result.metadata!.objects.keys,
        orderedEquals(const <String>['sales.vw_OrderSummary']),
      );
      expect(result.diagnostics, hasLength(1));
      expect(result.diagnostics.single.severity, GraphqlMetadataSeverity.error);
      expect(result.diagnostics.single.code, 'view_missing_identity');
      expect(result.diagnostics.single.objectId, 'sales.vw_OrderSummary');
    });

    test('emits metadata_object_unknown for declared objects absent from the physical model', () {
      const parser = GraphqlMetadataParser();

      final result = parser.parse(
        rawJsonc: '''
{
  version: 1,
  objects: {
    "sales.Missing": {
      publish: true,
    },
  },
}
''',
        physicalCatalog: _physicalCatalog(),
      );

      expect(result.metadata, isNotNull);
      expect(result.metadata!.objects.keys, orderedEquals(const <String>['sales.Missing']));
      expect(result.diagnostics, hasLength(1));
      expect(result.diagnostics.single.code, 'metadata_object_unknown');
      expect(result.diagnostics.single.objectId, 'sales.Missing');
    });

    test('rejects defaults and object limits where default is greater than max', () {
      const parser = GraphqlMetadataParser();

      final result = parser.parse(
        rawJsonc: '''
{
  version: 1,
  defaults: {
    limit: { default: 200, max: 50 },
  },
  objects: {
    "sales.Customer": {
      publish: true,
      limit: { default: 100, max: 25 },
    },
  },
}
''',
        physicalCatalog: _physicalCatalog(),
      );

      expect(result.metadata, isNotNull);
      expect(
        result.diagnostics.map((diagnostic) => diagnostic.code),
        containsAll(const <String>['metadata_invalid_shape', 'metadata_invalid_shape']),
      );
      expect(
        result.diagnostics.where((diagnostic) => diagnostic.field == 'defaults.limit'),
        hasLength(1),
      );
      expect(
        result.diagnostics.where((diagnostic) => diagnostic.field == 'sales.Customer.limit'),
        hasLength(1),
      );
    });

    test('sorts mixed error and warning diagnostics canonically', () {
      const parser = GraphqlMetadataParser();

      final result = parser.parse(
        rawJsonc: '''
{
  version: 1,
  futureKey: true,
  objects: {
    "sales.Unknown": {
      publish: true,
      stray: true,
    },
    "sales.vw_OrderSummary": {
      publish: true,
    },
  },
}
''',
        physicalCatalog: _physicalCatalog(),
      );

      expect(
        result.diagnostics
            .map((diagnostic) => '${diagnostic.severity.name}|${diagnostic.code}|${diagnostic.objectId ?? ''}|${diagnostic.field ?? ''}')
            .toList(growable: false),
        equals(const <String>[
          'error|metadata_object_unknown|sales.Unknown|',
          'error|view_missing_identity|sales.vw_OrderSummary|',
          'warning|metadata_unknown_key||futureKey',
          'warning|metadata_unknown_key|sales.Unknown|stray',
        ]),
      );
    });

    test('keeps a strict allowlist of declared publish true objects and leaves absent objects unpublished', () {
      const parser = GraphqlMetadataParser();

      final result = parser.parse(
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
        physicalCatalog: _physicalCatalog(),
      );

      expect(
        result.metadata!.objects.keys,
        orderedEquals(const <String>['sales.Customer']),
      );
      expect(result.metadata!.objects.containsKey('sales.vw_OrderSummary'), isFalse);
      expect(result.diagnostics, isEmpty);
    });

    test('parses field, relation, and limit overrides into strongly typed metadata', () {
      const parser = GraphqlMetadataParser();

      final result = parser.parse(
        rawJsonc: '''
{
  version: 1,
  defaults: {
    limit: { default: 50, max: 200 },
  },
  objects: {
    "sales.Customer": {
      publish: true,
      name: "CustomerRecord",
      key: ["CustomerId"],
      fields: {
        "CustomerCode": {
          hidden: true,
          noFilter: true,
          name: "customerCode",
        },
        "FullName": {
          sensitive: true,
          noSort: true,
        },
      },
      relations: [
        {
          name: "orders",
          cardinality: "to-many",
          target: "sales.Order",
          via: ["CustomerId"],
        },
      ],
      limit: { default: 25, max: 100 },
    },
  },
}
''',
        physicalCatalog: _physicalCatalog(),
      );

      final customer = result.metadata!.objects['sales.Customer'];
      expect(customer, isNotNull);
      expect(customer!.name, 'CustomerRecord');
      expect(customer.key, const <String>['CustomerId']);
      expect(result.metadata!.defaultsLimit, isNotNull);
      expect(result.metadata!.defaultsLimit!.defaultValue, 50);
      expect(result.metadata!.defaultsLimit!.maxValue, 200);
      expect(customer.limit, isNotNull);
      expect(customer.limit!.defaultValue, 25);
      expect(customer.limit!.maxValue, 100);
      expect(customer.fields.keys, orderedEquals(const <String>['CustomerCode', 'FullName']));
      expect(customer.fields['CustomerCode']!.hidden, isTrue);
      expect(customer.fields['CustomerCode']!.noFilter, isTrue);
      expect(customer.fields['CustomerCode']!.name, 'customerCode');
      expect(customer.fields['FullName']!.sensitive, isTrue);
      expect(customer.fields['FullName']!.noSort, isTrue);
      expect(customer.relations, hasLength(1));
      expect(customer.relations.single.name, 'orders');
      expect(customer.relations.single.cardinality, 'to-many');
      expect(customer.relations.single.target, 'sales.Order');
      expect(customer.relations.single.via, const <String>['CustomerId']);
      expect(result.diagnostics, isEmpty);
    });
  });
}

PhysicalCatalog _physicalCatalog() {
  return const PhysicalCatalog(
    objects: <PhysicalObject>[
      PhysicalObject(
        id: 'sales.Customer',
        kind: PhysicalObjectKind.table,
        schemaName: 'sales',
        objectName: 'Customer',
        identityFields: <String>['CustomerId'],
        fields: <PhysicalField>[],
        relations: <PhysicalRelationSeed>[],
      ),
      PhysicalObject(
        id: 'sales.vw_OrderSummary',
        kind: PhysicalObjectKind.view,
        schemaName: 'sales',
        objectName: 'vw_OrderSummary',
        identityFields: <String>[],
        fields: <PhysicalField>[],
        relations: <PhysicalRelationSeed>[],
      ),
    ],
  );
}