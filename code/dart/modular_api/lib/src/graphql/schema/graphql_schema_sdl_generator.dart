import 'package:modular_api/src/graphql/catalog/graphql_catalog_builder.dart';

final class GraphqlSchemaSdlGenerator {
  const GraphqlSchemaSdlGenerator();

  String generate(GraphqlCatalog catalog) {
    final objects = catalog.objects.toList(growable: false)
      ..sort((left, right) => left.id.compareTo(right.id));
    final objectById = <String, GraphqlPublishedObject>{
      for (final object in objects) object.id: object,
    };

    final blocks = <String>[];
    final customScalars = _collectCustomScalars(objects);
    if (customScalars.isNotEmpty) {
      blocks.add(customScalars.map((scalar) => 'scalar $scalar').join('\n'));
    }

    blocks.add(_buildQueryType(objects));

    for (final object in objects) {
      blocks.add(_buildObjectType(object, objectById));
      blocks.add(_buildListEnvelope(object));
      if (object.capabilities.item && object.graphql.itemField != null) {
        blocks.add(_buildKeyInput(object));
      }
      blocks.add(_buildFilterInput(object));
      blocks.add(_buildOrderByInput(object));
      blocks.add(_buildOrderFieldEnum(object));
    }

    final usedFilterFamilies = _collectUsedFilterFamilies(objects);
    for (final family in usedFilterFamilies) {
      blocks.add(_buildScalarFilterInput(family));
    }

    blocks.add('''
enum SortDirection {
  ASC
  DESC
}''');
    blocks.add('''
input OffsetPageInput {
  limit: Int
  offset: Int
}''');

    return blocks.join('\n\n');
  }

  List<String> _collectCustomScalars(List<GraphqlPublishedObject> objects) {
    final usedScalars = <String>{};
    for (final object in objects) {
      for (final field in object.fields) {
        if (_isCustomScalar(field.type)) {
          usedScalars.add(field.type);
        }
      }
    }

    final scalars = usedScalars.toList(growable: false)..sort();
    return scalars;
  }

  String _buildQueryType(List<GraphqlPublishedObject> objects) {
    final lines = <String>['type Query {'];

    for (final object in objects) {
      if (object.capabilities.item && object.graphql.itemField != null) {
        lines.add(
          '  ${object.graphql.itemField}(key: ${object.graphql.typeName}KeyInput!): ${object.graphql.typeName}',
        );
      }
      if (object.capabilities.collection) {
        lines.add('  ${object.graphql.collectionField}(');
        lines.add('    filter: ${object.graphql.typeName}FilterInput');
        lines.add('    orderBy: [${object.graphql.typeName}OrderByInput!]');
        lines.add('    page: OffsetPageInput');
        lines.add('  ): ${object.graphql.typeName}List!');
      }
    }

    lines.add('}');
    return lines.join('\n');
  }

  String _buildObjectType(
    GraphqlPublishedObject object,
    Map<String, GraphqlPublishedObject> objectById,
  ) {
    final lines = <String>['type ${object.graphql.typeName} {'];
    for (final field in object.fields.where(
      (field) => field.visibility == GraphqlCatalogFieldVisibility.public,
    )) {
      lines.add('  ${field.publicName}: ${_graphqlFieldType(field.type, field.nullable)}');
    }
    for (final relation in object.relations) {
      final target = objectById[relation.target];
      if (target == null) {
        continue;
      }
      final relationType = relation.cardinality == GraphqlCatalogRelationCardinality.many
          ? '[${target.graphql.typeName}!]!'
          : target.graphql.typeName;
      lines.add('  ${relation.name}: $relationType');
    }
    lines.add('}');
    return lines.join('\n');
  }

  String _buildListEnvelope(GraphqlPublishedObject object) {
    return '''
type ${object.graphql.typeName}List {
  items: [${object.graphql.typeName}!]!
  totalCount: Int!
}''';
  }

  String _buildKeyInput(GraphqlPublishedObject object) {
    final fieldByColumn = <String, GraphqlCatalogField>{
      for (final field in object.fields) field.column: field,
    };
    final lines = <String>['input ${object.graphql.typeName}KeyInput {'];
    for (final column in object.identity.fields) {
      final field = fieldByColumn[column];
      if (field == null) {
        continue;
      }
      lines.add('  ${field.publicName}: ${field.type}!');
    }
    lines.add('}');
    return lines.join('\n');
  }

  String _buildFilterInput(GraphqlPublishedObject object) {
    final lines = <String>['input ${object.graphql.typeName}FilterInput {'];
    lines.add('  and: [${object.graphql.typeName}FilterInput!]');
    lines.add('  or: [${object.graphql.typeName}FilterInput!]');
    lines.add('  not: ${object.graphql.typeName}FilterInput');
    for (final field in object.fields.where(
      (field) =>
          field.visibility == GraphqlCatalogFieldVisibility.public &&
          field.filterable &&
          field.type != 'Json',
    )) {
      lines.add('  ${field.publicName}: ${field.type}FilterInput');
    }
    lines.add('}');
    return lines.join('\n');
  }

  String _buildOrderByInput(GraphqlPublishedObject object) {
    return '''
input ${object.graphql.typeName}OrderByInput {
  field: ${object.graphql.typeName}OrderField!
  direction: SortDirection!
}''';
  }

  String _buildOrderFieldEnum(GraphqlPublishedObject object) {
    final lines = <String>['enum ${object.graphql.typeName}OrderField {'];
    for (final field in object.fields.where(
      (field) =>
          field.visibility == GraphqlCatalogFieldVisibility.public && field.sortable,
    )) {
      lines.add('  ${_enumValueForFieldName(field.publicName)}');
    }
    lines.add('}');
    return lines.join('\n');
  }

  List<String> _collectUsedFilterFamilies(List<GraphqlPublishedObject> objects) {
    final families = <String>{};
    for (final object in objects) {
      for (final field in object.fields) {
        if (field.visibility == GraphqlCatalogFieldVisibility.public &&
            field.filterable &&
            field.type != 'Json') {
          families.add(field.type);
        }
      }
    }
    final sorted = families.toList(growable: false)..sort();
    return sorted;
  }

  String _buildScalarFilterInput(String scalar) {
    switch (scalar) {
      case 'String':
        return '''
input StringFilterInput {
  eq: String
  ne: String
  in: [String!]
  contains: String
  startsWith: String
  endsWith: String
  isNull: Boolean
}''';
      case 'Boolean':
        return '''
input BooleanFilterInput {
  eq: Boolean
  ne: Boolean
  isNull: Boolean
}''';
      case 'Uuid':
        return '''
input UuidFilterInput {
  eq: Uuid
  ne: Uuid
  in: [Uuid!]
  isNull: Boolean
}''';
      case 'Int':
      case 'Long':
      case 'Float':
      case 'Decimal':
      case 'Date':
      case 'DateTime':
        return '''
input ${scalar}FilterInput {
  eq: $scalar
  ne: $scalar
  in: [$scalar!]
  lt: $scalar
  lte: $scalar
  gt: $scalar
  gte: $scalar
  isNull: Boolean
}''';
      case 'Json':
        throw StateError('Json fields do not expose scalar filter operators in v1.');
    }
    throw StateError('Unsupported scalar family $scalar for filter input generation.');
  }

  bool _isCustomScalar(String scalar) {
    return switch (scalar) {
      'Long' || 'Decimal' || 'Date' || 'DateTime' || 'Uuid' || 'Json' => true,
      _ => false,
    };
  }

  String _graphqlFieldType(String scalar, bool nullable) {
    return nullable ? scalar : '$scalar!';
  }

  String _enumValueForFieldName(String publicName) {
    final words = <String>[];
    final segmentPattern = RegExp(r'[A-Za-z0-9]+');
    final wordPattern = RegExp(
      r'[A-Z]+(?:\d+)?(?=[A-Z][a-z]|$)|[A-Z]?[a-z]+\d*|\d+',
    );

    for (final segmentMatch in segmentPattern.allMatches(publicName)) {
      final segment = segmentMatch.group(0)!;
      for (final wordMatch in wordPattern.allMatches(segment)) {
        final word = wordMatch.group(0)!;
        if (word.isNotEmpty) {
          words.add(word.toUpperCase());
        }
      }
    }

    return words.join('_');
  }
}