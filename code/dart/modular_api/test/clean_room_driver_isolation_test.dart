import 'dart:io';

import 'package:modular_api/modular_api.dart';
import 'package:test/test.dart';

void main() {
  test('core pubspec excludes concrete database drivers', () {
    final contents = File('pubspec.yaml').readAsStringSync();

    expect(
      contents,
      isNot(contains('dart_odbc:')),
      reason: 'modular_api base must not own the SQL Server driver',
    );
    expect(
      contents,
      isNot(contains('postgres:')),
      reason: 'modular_api base must not own the Postgres driver',
    );
  });

  test('core package import remains green without concrete database drivers', () {
    const parser = GraphqlMetadataParser();
    const catalog = PhysicalCatalog(objects: <PhysicalObject>[]);

    expect(parser, isA<GraphqlMetadataParser>());
    expect(catalog.objects, isEmpty);
  });
}