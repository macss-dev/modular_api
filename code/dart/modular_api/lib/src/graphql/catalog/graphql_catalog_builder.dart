import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:modular_api/src/graphql/metadata/graphql_metadata_parser.dart';
import 'package:modular_api/src/graphql/sqlserver/physical_model.dart';

enum GraphqlCatalogBuildMode {
  compile,
  runtime,
}

enum GraphqlCatalogDiagnosticSeverity {
  error,
  warning,
  info,
}

enum GraphqlCatalogOrigin {
  inferred,
  annotated,
}

enum GraphqlCatalogIdentityMode {
  single,
  composite,
  none,
}

enum GraphqlCatalogFieldVisibility {
  public,
  hidden,
}

enum GraphqlCatalogRelationCardinality {
  one,
  many,
}

enum GraphqlCatalogPaginationMode {
  offset,
  none,
}

final class GraphqlCatalogDiagnostic {
  const GraphqlCatalogDiagnostic({
    required this.severity,
    required this.code,
    required this.message,
    this.objectId,
    this.field,
  });

  final GraphqlCatalogDiagnosticSeverity severity;
  final String code;
  final String message;
  final String? objectId;
  final String? field;
}

final class GraphqlCatalogProvider {
  const GraphqlCatalogProvider({
    required this.kind,
    required this.engine,
    required this.providerVersion,
  });

  final String kind;
  final String engine;
  final String providerVersion;
}

final class GraphqlCatalogBuild {
  const GraphqlCatalogBuild({
    required this.mode,
    required this.sourceRoot,
    required this.sourceDigest,
  });

  final GraphqlCatalogBuildMode mode;
  final String sourceRoot;
  final String sourceDigest;
}

final class GraphqlCatalogGraphqlNames {
  const GraphqlCatalogGraphqlNames({
    required this.typeName,
    required this.collectionField,
    required this.itemField,
  });

  final String typeName;
  final String collectionField;
  final String? itemField;
}

final class GraphqlCatalogSource {
  const GraphqlCatalogSource({
    required this.schemaName,
    required this.objectName,
    this.sourceFile,
    this.providerObjectId,
  });

  final String schemaName;
  final String objectName;
  final String? sourceFile;
  final String? providerObjectId;
}

final class GraphqlCatalogIdentity {
  const GraphqlCatalogIdentity({
    required this.mode,
    required this.fields,
    required this.origin,
  });

  final GraphqlCatalogIdentityMode mode;
  final List<String> fields;
  final GraphqlCatalogOrigin origin;
}

final class GraphqlCatalogField {
  const GraphqlCatalogField({
    required this.column,
    required this.publicName,
    required this.type,
    required this.nullable,
    required this.visibility,
    required this.filterable,
    required this.sortable,
    required this.sensitive,
    required this.origin,
  });

  final String column;
  final String publicName;
  final String type;
  final bool nullable;
  final GraphqlCatalogFieldVisibility visibility;
  final bool filterable;
  final bool sortable;
  final bool sensitive;
  final GraphqlCatalogOrigin origin;
}

final class GraphqlCatalogRelation {
  const GraphqlCatalogRelation({
    required this.name,
    required this.target,
    required this.cardinality,
    required this.sourceFields,
    required this.targetFields,
    required this.origin,
  });

  final String name;
  final String target;
  final GraphqlCatalogRelationCardinality cardinality;
  final List<String> sourceFields;
  final List<String> targetFields;
  final GraphqlCatalogOrigin origin;
}

final class GraphqlCatalogPagination {
  const GraphqlCatalogPagination({
    required this.mode,
    required this.defaultLimit,
    required this.maxLimit,
  });

  final GraphqlCatalogPaginationMode mode;
  final int defaultLimit;
  final int maxLimit;
}

final class GraphqlCatalogCapabilities {
  const GraphqlCatalogCapabilities({
    required this.item,
    required this.collection,
    required this.filter,
    required this.sort,
    required this.pagination,
  });

  final bool item;
  final bool collection;
  final bool filter;
  final bool sort;
  final GraphqlCatalogPagination pagination;
}

final class GraphqlPublishedObject {
  const GraphqlPublishedObject({
    required this.id,
    required this.kind,
    required this.readonly,
    required this.source,
    required this.graphql,
    required this.identity,
    required this.fields,
    required this.relations,
    required this.capabilities,
  });

  final String id;
  final PhysicalObjectKind kind;
  final bool readonly;
  final GraphqlCatalogSource source;
  final GraphqlCatalogGraphqlNames graphql;
  final GraphqlCatalogIdentity identity;
  final List<GraphqlCatalogField> fields;
  final List<GraphqlCatalogRelation> relations;
  final GraphqlCatalogCapabilities capabilities;
}

final class GraphqlCatalog {
  const GraphqlCatalog({
    required this.catalogVersion,
    required this.provider,
    required this.build,
    required this.objects,
    required this.diagnostics,
  });

  final String catalogVersion;
  final GraphqlCatalogProvider provider;
  final GraphqlCatalogBuild build;
  final List<GraphqlPublishedObject> objects;
  final List<GraphqlCatalogDiagnostic> diagnostics;
}

final class GraphqlCatalogNaming {
  const GraphqlCatalogNaming._();

  static String typeNameForObjectName(String value) {
    final tokens = _tokenize(value);
    if (tokens.isEmpty) {
      return '';
    }

    return tokens.map(_pascalToken).join();
  }

  static String publicFieldNameForColumn(String value) {
    final tokens = _tokenize(value);
    if (tokens.isEmpty) {
      return '';
    }

    final head = _pascalToken(tokens.first);
    final tail = tokens.skip(1).map(_pascalToken).join();
    return _camelToken(head) + tail;
  }

  static List<String> _tokenize(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return const <String>[];
    }

    final tokens = <String>[];
    final segmentPattern = RegExp(r'[A-Za-z0-9]+');
    final wordPattern = RegExp(
      r'[A-Z]+(?:\d+)?(?=[A-Z][a-z]|$)|[A-Z]?[a-z]+\d*|\d+',
    );

    for (final segmentMatch in segmentPattern.allMatches(trimmed)) {
      final segment = segmentMatch.group(0)!;
      final words = wordPattern
          .allMatches(segment)
          .map((match) => match.group(0)!)
          .where((token) => token.isNotEmpty);
      tokens.addAll(words);
    }

    return tokens;
  }

  static String _pascalToken(String token) {
    if (token.isEmpty) {
      return token;
    }
    if (RegExp(r'^\d+$').hasMatch(token)) {
      return token;
    }

    final lower = token.toLowerCase();
    return '${lower[0].toUpperCase()}${lower.substring(1)}';
  }

  static String _camelToken(String token) {
    if (token.isEmpty) {
      return token;
    }

    return '${token[0].toLowerCase()}${token.substring(1)}';
  }
}

final class GraphqlCatalogBuilder {
  const GraphqlCatalogBuilder({
    required this.providerVersion,
    required this.sourceRoot,
    required this.buildMode,
    required this.engine,
  });

  final String providerVersion;
  final String sourceRoot;
  final GraphqlCatalogBuildMode buildMode;
  final String engine;

  GraphqlCatalog build({
    required PhysicalCatalog physicalCatalog,
    required GraphqlMetadataFile metadata,
  }) {
    final diagnostics = <GraphqlCatalogDiagnostic>[];
    final physicalObjectsById = <String, PhysicalObject>{
      for (final object in physicalCatalog.objects) object.id: object,
    };

    final contexts = <String, _CatalogObjectContext>{};
    final objectIds = metadata.objects.keys.toList(growable: false)..sort();

    for (final objectId in objectIds) {
      final physicalObject = physicalObjectsById[objectId];
      if (physicalObject == null) {
        diagnostics.add(
          GraphqlCatalogDiagnostic(
            severity: GraphqlCatalogDiagnosticSeverity.error,
            code: 'metadata_object_unknown',
            message: 'Metadata references an object not present in the physical model.',
            objectId: objectId,
          ),
        );
        continue;
      }

      final objectMetadata = metadata.objects[objectId]!;
      final identity = _resolveIdentity(
        physicalObject: physicalObject,
        objectMetadata: objectMetadata,
        diagnostics: diagnostics,
      );
      final typeName = objectMetadata.name ??
          GraphqlCatalogNaming.typeNameForObjectName(physicalObject.objectName);
      final itemField = identity.mode == GraphqlCatalogIdentityMode.none
          ? null
          : GraphqlCatalogNaming.publicFieldNameForColumn(typeName);
      final collectionField = '${GraphqlCatalogNaming.publicFieldNameForColumn(typeName)}List';

      contexts[objectId] = _CatalogObjectContext(
        physicalObject: physicalObject,
        objectMetadata: objectMetadata,
        typeName: typeName,
        itemField: itemField,
        collectionField: collectionField,
        identity: identity,
      );
    }

    final objects = contexts.keys
        .map((objectId) => _buildObject(
              context: contexts[objectId]!,
              allContexts: contexts,
              defaultsLimit: metadata.defaultsLimit,
              diagnostics: diagnostics,
            ))
        .toList(growable: false)
      ..sort((left, right) => left.id.compareTo(right.id));

    _detectDuplicateObjectNames(objects, diagnostics);
    final sortedDiagnostics = _sortDiagnostics(diagnostics);

    final catalog = GraphqlCatalog(
      catalogVersion: '1.0.0',
      provider: GraphqlCatalogProvider(
        kind: 'sql',
        engine: engine,
        providerVersion: providerVersion,
      ),
      build: GraphqlCatalogBuild(
        mode: buildMode,
        sourceRoot: sourceRoot,
        sourceDigest: '',
      ),
      objects: objects,
      diagnostics: sortedDiagnostics,
    );

    final digest = _computeSourceDigest(catalog);
    return GraphqlCatalog(
      catalogVersion: catalog.catalogVersion,
      provider: catalog.provider,
      build: GraphqlCatalogBuild(
        mode: catalog.build.mode,
        sourceRoot: catalog.build.sourceRoot,
        sourceDigest: digest,
      ),
      objects: catalog.objects,
      diagnostics: catalog.diagnostics,
    );
  }

  GraphqlCatalogIdentity _resolveIdentity({
    required PhysicalObject physicalObject,
    required GraphqlObjectMetadata objectMetadata,
    required List<GraphqlCatalogDiagnostic> diagnostics,
  }) {
    if (objectMetadata.key case final List<String> keyFields
        when keyFields.isNotEmpty) {
      return GraphqlCatalogIdentity(
        mode: keyFields.length == 1
            ? GraphqlCatalogIdentityMode.single
            : GraphqlCatalogIdentityMode.composite,
        fields: List<String>.unmodifiable(keyFields),
        origin: GraphqlCatalogOrigin.annotated,
      );
    }

    if (physicalObject.identityFields.isNotEmpty) {
      return GraphqlCatalogIdentity(
        mode: physicalObject.identityFields.length == 1
            ? GraphqlCatalogIdentityMode.single
            : GraphqlCatalogIdentityMode.composite,
        fields: List<String>.unmodifiable(physicalObject.identityFields),
        origin: GraphqlCatalogOrigin.inferred,
      );
    }

    if (physicalObject.kind == PhysicalObjectKind.view) {
      diagnostics.add(
        GraphqlCatalogDiagnostic(
          severity: GraphqlCatalogDiagnosticSeverity.error,
          code: 'view_missing_identity',
          message: 'Published view requires explicit identity metadata.',
          objectId: physicalObject.id,
        ),
      );
    }

    return const GraphqlCatalogIdentity(
      mode: GraphqlCatalogIdentityMode.none,
      fields: <String>[],
      origin: GraphqlCatalogOrigin.inferred,
    );
  }

  GraphqlPublishedObject _buildObject({
    required _CatalogObjectContext context,
    required Map<String, _CatalogObjectContext> allContexts,
    required GraphqlMetadataLimit? defaultsLimit,
    required List<GraphqlCatalogDiagnostic> diagnostics,
  }) {
    final physicalObject = context.physicalObject;
    final objectMetadata = context.objectMetadata;
    final fields = physicalObject.fields
        .map((field) => _buildField(
              objectId: physicalObject.id,
              physicalField: field,
              fieldMetadata: objectMetadata.fields[field.column],
              diagnostics: diagnostics,
            ))
        .toList(growable: false)
      ..sort((left, right) {
        final byPublicName = left.publicName.compareTo(right.publicName);
        if (byPublicName != 0) {
          return byPublicName;
        }
        return left.column.compareTo(right.column);
      });

    _detectDuplicateFieldNames(physicalObject.id, fields, diagnostics);

    final relations = _buildRelations(
      context: context,
      allContexts: allContexts,
      diagnostics: diagnostics,
    );
    final pagination = _resolvePagination(
      objectMetadata.limit,
      defaultsLimit,
    );
    final capabilities = GraphqlCatalogCapabilities(
      item: context.identity.mode != GraphqlCatalogIdentityMode.none,
      collection: true,
      filter: fields.any((field) =>
          field.visibility == GraphqlCatalogFieldVisibility.public &&
          field.filterable),
      sort: fields.any((field) =>
          field.visibility == GraphqlCatalogFieldVisibility.public &&
          field.sortable),
      pagination: pagination,
    );

    return GraphqlPublishedObject(
      id: physicalObject.id,
      kind: physicalObject.kind,
      readonly: true,
      source: GraphqlCatalogSource(
        schemaName: physicalObject.schemaName,
        objectName: physicalObject.objectName,
      ),
      graphql: GraphqlCatalogGraphqlNames(
        typeName: context.typeName,
        collectionField: context.collectionField,
        itemField: context.itemField,
      ),
      identity: context.identity,
      fields: List<GraphqlCatalogField>.unmodifiable(fields),
      relations: List<GraphqlCatalogRelation>.unmodifiable(relations),
      capabilities: capabilities,
    );
  }

  GraphqlCatalogField _buildField({
    required String objectId,
    required PhysicalField physicalField,
    required GraphqlFieldMetadata? fieldMetadata,
    required List<GraphqlCatalogDiagnostic> diagnostics,
  }) {
    final type = _normalizeScalar(
      objectId: objectId,
      column: physicalField.column,
      nativeType: physicalField.nativeType,
      diagnostics: diagnostics,
    );
    final publicName = fieldMetadata?.name ??
        GraphqlCatalogNaming.publicFieldNameForColumn(physicalField.column);
    final visibility = fieldMetadata?.hidden == true
        ? GraphqlCatalogFieldVisibility.hidden
        : GraphqlCatalogFieldVisibility.public;
    final filterable = visibility == GraphqlCatalogFieldVisibility.public &&
        fieldMetadata?.noFilter != true &&
        type != 'Json';
    final sortable = visibility == GraphqlCatalogFieldVisibility.public &&
        fieldMetadata?.noSort != true &&
        type != 'Json';

    return GraphqlCatalogField(
      column: physicalField.column,
      publicName: publicName,
      type: type,
      nullable: physicalField.nullable,
      visibility: visibility,
      filterable: filterable,
      sortable: sortable,
      sensitive: fieldMetadata?.sensitive ?? false,
      origin: fieldMetadata == null
          ? GraphqlCatalogOrigin.inferred
          : GraphqlCatalogOrigin.annotated,
    );
  }

  List<GraphqlCatalogRelation> _buildRelations({
    required _CatalogObjectContext context,
    required Map<String, _CatalogObjectContext> allContexts,
    required List<GraphqlCatalogDiagnostic> diagnostics,
  }) {
    final relations = <GraphqlCatalogRelation>[];
    final physicalObject = context.physicalObject;

    if (physicalObject.kind == PhysicalObjectKind.table) {
      for (final relationSeed in physicalObject.relations) {
        final targetContext = allContexts[relationSeed.targetObjectId];
        if (targetContext == null) {
          diagnostics.add(
            GraphqlCatalogDiagnostic(
              severity: GraphqlCatalogDiagnosticSeverity.error,
              code: 'relation_target_unknown',
              message: 'Relation target is not published in the governed catalog.',
              objectId: physicalObject.id,
              field: relationSeed.name,
            ),
          );
          continue;
        }

        relations.add(
          GraphqlCatalogRelation(
            name: GraphqlCatalogNaming.publicFieldNameForColumn(relationSeed.name),
            target: relationSeed.targetObjectId,
            cardinality: GraphqlCatalogRelationCardinality.one,
            sourceFields: List<String>.unmodifiable(relationSeed.sourceFields),
            targetFields: List<String>.unmodifiable(relationSeed.targetFields),
            origin: GraphqlCatalogOrigin.inferred,
          ),
        );
      }
    } else {
      for (final relationMetadata in context.objectMetadata.relations) {
        final targetContext = allContexts[relationMetadata.target];
        if (targetContext == null ||
            targetContext.identity.mode == GraphqlCatalogIdentityMode.none) {
          diagnostics.add(
            GraphqlCatalogDiagnostic(
              severity: GraphqlCatalogDiagnosticSeverity.error,
              code: 'relation_target_unknown',
              message: 'Relation target is not published with usable identity.',
              objectId: physicalObject.id,
              field: relationMetadata.name,
            ),
          );
          continue;
        }

        relations.add(
          GraphqlCatalogRelation(
            name: relationMetadata.name,
            target: relationMetadata.target,
            cardinality: relationMetadata.cardinality == 'to-many'
                ? GraphqlCatalogRelationCardinality.many
                : GraphqlCatalogRelationCardinality.one,
            sourceFields: List<String>.unmodifiable(relationMetadata.via),
            targetFields: List<String>.unmodifiable(targetContext.identity.fields),
            origin: GraphqlCatalogOrigin.annotated,
          ),
        );
      }
    }

    relations.sort((left, right) {
      final byName = left.name.compareTo(right.name);
      if (byName != 0) {
        return byName;
      }
      return left.target.compareTo(right.target);
    });
    return relations;
  }

  GraphqlCatalogPagination _resolvePagination(
    GraphqlMetadataLimit? objectLimit,
    GraphqlMetadataLimit? defaultsLimit,
  ) {
    final effectiveLimit = objectLimit ??
        defaultsLimit ??
        const GraphqlMetadataLimit(defaultValue: 50, maxValue: 200);
    return GraphqlCatalogPagination(
      mode: GraphqlCatalogPaginationMode.offset,
      defaultLimit: effectiveLimit.defaultValue,
      maxLimit: effectiveLimit.maxValue,
    );
  }

  String _normalizeScalar({
    required String objectId,
    required String column,
    required String nativeType,
    required List<GraphqlCatalogDiagnostic> diagnostics,
  }) {
    final normalized = nativeType.trim().toLowerCase();
    if (normalized.startsWith('bigint')) {
      return 'Long';
    }
    if (normalized.startsWith('int') ||
        normalized.startsWith('smallint') ||
        normalized.startsWith('tinyint')) {
      return 'Int';
    }
    if (normalized.startsWith('decimal') ||
        normalized.startsWith('numeric') ||
        normalized.startsWith('money') ||
        normalized.startsWith('smallmoney')) {
      return 'Decimal';
    }
    if (normalized.startsWith('float') || normalized.startsWith('real')) {
      return 'Float';
    }
    if (normalized.startsWith('bit')) {
      return 'Boolean';
    }
    if (normalized.startsWith('date') && !normalized.startsWith('datetime')) {
      return 'Date';
    }
    if (normalized.startsWith('datetime') ||
        normalized.startsWith('smalldatetime') ||
        normalized.startsWith('datetimeoffset')) {
      return 'DateTime';
    }
    if (normalized.startsWith('uniqueidentifier')) {
      return 'Uuid';
    }
    if (normalized.startsWith('json')) {
      return 'Json';
    }
    if (normalized.startsWith('char') ||
        normalized.startsWith('nchar') ||
        normalized.startsWith('varchar') ||
        normalized.startsWith('nvarchar') ||
        normalized.startsWith('text') ||
        normalized.startsWith('ntext') ||
        normalized.startsWith('xml')) {
      return 'String';
    }

    diagnostics.add(
      GraphqlCatalogDiagnostic(
        severity: GraphqlCatalogDiagnosticSeverity.warning,
        code: 'unsupported_scalar',
        message: 'Native type $nativeType is not mapped explicitly in the v1 scalar domain.',
        objectId: objectId,
        field: column,
      ),
    );
    return 'String';
  }

  void _detectDuplicateFieldNames(
    String objectId,
    List<GraphqlCatalogField> fields,
    List<GraphqlCatalogDiagnostic> diagnostics,
  ) {
    final counts = <String, int>{};
    for (final field in fields) {
      counts.update(field.publicName, (value) => value + 1, ifAbsent: () => 1);
    }

    final duplicates = counts.entries
        .where((entry) => entry.value > 1)
        .map((entry) => entry.key)
        .toList(growable: false)
      ..sort();

    for (final publicName in duplicates) {
      diagnostics.add(
        GraphqlCatalogDiagnostic(
          severity: GraphqlCatalogDiagnosticSeverity.error,
          code: 'duplicate_public_name',
          message: 'Multiple fields derive the same public GraphQL name.',
          objectId: objectId,
          field: publicName,
        ),
      );
    }
  }

  void _detectDuplicateObjectNames(
    List<GraphqlPublishedObject> objects,
    List<GraphqlCatalogDiagnostic> diagnostics,
  ) {
    final typeCounts = <String, int>{};
    final itemCounts = <String, int>{};
    final collectionCounts = <String, int>{};

    for (final object in objects) {
      typeCounts.update(object.graphql.typeName, (value) => value + 1,
          ifAbsent: () => 1);
      collectionCounts.update(
        object.graphql.collectionField,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
      if (object.graphql.itemField case final String itemField) {
        itemCounts.update(itemField, (value) => value + 1, ifAbsent: () => 1);
      }
    }

    for (final object in objects) {
      if (typeCounts[object.graphql.typeName]! > 1) {
        diagnostics.add(
          GraphqlCatalogDiagnostic(
            severity: GraphqlCatalogDiagnosticSeverity.error,
            code: 'duplicate_public_name',
            message: 'Multiple objects derive the same GraphQL type name.',
            objectId: object.id,
            field: object.graphql.typeName,
          ),
        );
      }
      if (collectionCounts[object.graphql.collectionField]! > 1) {
        diagnostics.add(
          GraphqlCatalogDiagnostic(
            severity: GraphqlCatalogDiagnosticSeverity.error,
            code: 'duplicate_public_name',
            message: 'Multiple objects derive the same collection field name.',
            objectId: object.id,
            field: object.graphql.collectionField,
          ),
        );
      }
      if (object.graphql.itemField case final String itemField
          when itemCounts[itemField]! > 1) {
        diagnostics.add(
          GraphqlCatalogDiagnostic(
            severity: GraphqlCatalogDiagnosticSeverity.error,
            code: 'duplicate_public_name',
            message: 'Multiple objects derive the same item field name.',
            objectId: object.id,
            field: itemField,
          ),
        );
      }
    }
  }

  List<GraphqlCatalogDiagnostic> _sortDiagnostics(
    List<GraphqlCatalogDiagnostic> diagnostics,
  ) {
    final sorted = diagnostics.toList(growable: false);
    sorted.sort((left, right) {
      final bySeverity =
          left.severity.index.compareTo(right.severity.index);
      if (bySeverity != 0) {
        return bySeverity;
      }

      final byCode = left.code.compareTo(right.code);
      if (byCode != 0) {
        return byCode;
      }

      final byObjectId =
          (left.objectId ?? '').compareTo(right.objectId ?? '');
      if (byObjectId != 0) {
        return byObjectId;
      }

      final byField = (left.field ?? '').compareTo(right.field ?? '');
      if (byField != 0) {
        return byField;
      }

      return left.message.compareTo(right.message);
    });
    return sorted;
  }

  String _computeSourceDigest(GraphqlCatalog catalog) {
    final payload = <String, Object?>{
      'engine': engine,
      'providerVersion': providerVersion,
      'sourceRoot': sourceRoot,
      'buildMode': _buildModeValue(buildMode),
      'objects': catalog.objects.map(_objectDigestMap).toList(growable: false),
    };
    final canonicalJson = jsonEncode(_canonicalize(payload));
    return sha256.convert(utf8.encode(canonicalJson)).toString();
  }

  Map<String, Object?> _objectDigestMap(GraphqlPublishedObject object) {
    return <String, Object?>{
      'id': object.id,
      'kind': _kindValue(object.kind),
      'source': <String, Object?>{
        'schemaName': object.source.schemaName,
        'objectName': object.source.objectName,
        'sourceFile': object.source.sourceFile,
        'providerObjectId': object.source.providerObjectId,
      },
      'graphql': <String, Object?>{
        'typeName': object.graphql.typeName,
        'collectionField': object.graphql.collectionField,
        'itemField': object.graphql.itemField,
      },
      'identity': <String, Object?>{
        'mode': _identityModeValue(object.identity.mode),
        'fields': object.identity.fields,
        'origin': _originValue(object.identity.origin),
      },
      'fields': object.fields.map((field) => <String, Object?>{
            'column': field.column,
            'publicName': field.publicName,
            'type': field.type,
            'nullable': field.nullable,
            'visibility': _visibilityValue(field.visibility),
            'filterable': field.filterable,
            'sortable': field.sortable,
            'sensitive': field.sensitive,
            'origin': _originValue(field.origin),
          }).toList(growable: false),
      'relations': object.relations.map((relation) => <String, Object?>{
            'name': relation.name,
            'target': relation.target,
            'cardinality': _relationCardinalityValue(relation.cardinality),
            'sourceFields': relation.sourceFields,
            'targetFields': relation.targetFields,
            'origin': _originValue(relation.origin),
          }).toList(growable: false),
      'capabilities': <String, Object?>{
        'item': object.capabilities.item,
        'collection': object.capabilities.collection,
        'filter': object.capabilities.filter,
        'sort': object.capabilities.sort,
        'pagination': <String, Object?>{
          'mode': _paginationModeValue(object.capabilities.pagination.mode),
          'defaultLimit': object.capabilities.pagination.defaultLimit,
          'maxLimit': object.capabilities.pagination.maxLimit,
        },
      },
    };
  }

  Object? _canonicalize(Object? value) {
    if (value is Map) {
      final entries = value.entries
          .map((entry) => MapEntry(entry.key.toString(), _canonicalize(entry.value)))
          .toList(growable: false)
        ..sort((left, right) => left.key.compareTo(right.key));
      final sorted = SplayTreeMap<String, Object?>();
      for (final entry in entries) {
        sorted[entry.key] = entry.value;
      }
      return sorted;
    }
    if (value is List) {
      return value.map(_canonicalize).toList(growable: false);
    }
    return value;
  }

  String _buildModeValue(GraphqlCatalogBuildMode value) {
    switch (value) {
      case GraphqlCatalogBuildMode.compile:
        return 'compile';
      case GraphqlCatalogBuildMode.runtime:
        return 'runtime';
    }
  }

  String _kindValue(PhysicalObjectKind value) {
    switch (value) {
      case PhysicalObjectKind.table:
        return 'table';
      case PhysicalObjectKind.view:
        return 'view';
    }
  }

  String _identityModeValue(GraphqlCatalogIdentityMode value) {
    switch (value) {
      case GraphqlCatalogIdentityMode.single:
        return 'single';
      case GraphqlCatalogIdentityMode.composite:
        return 'composite';
      case GraphqlCatalogIdentityMode.none:
        return 'none';
    }
  }

  String _originValue(GraphqlCatalogOrigin value) {
    switch (value) {
      case GraphqlCatalogOrigin.inferred:
        return 'inferred';
      case GraphqlCatalogOrigin.annotated:
        return 'annotated';
    }
  }

  String _visibilityValue(GraphqlCatalogFieldVisibility value) {
    switch (value) {
      case GraphqlCatalogFieldVisibility.public:
        return 'public';
      case GraphqlCatalogFieldVisibility.hidden:
        return 'hidden';
    }
  }

  String _relationCardinalityValue(GraphqlCatalogRelationCardinality value) {
    switch (value) {
      case GraphqlCatalogRelationCardinality.one:
        return 'one';
      case GraphqlCatalogRelationCardinality.many:
        return 'many';
    }
  }

  String _paginationModeValue(GraphqlCatalogPaginationMode value) {
    switch (value) {
      case GraphqlCatalogPaginationMode.offset:
        return 'offset';
      case GraphqlCatalogPaginationMode.none:
        return 'none';
    }
  }
}

final class _CatalogObjectContext {
  const _CatalogObjectContext({
    required this.physicalObject,
    required this.objectMetadata,
    required this.typeName,
    required this.itemField,
    required this.collectionField,
    required this.identity,
  });

  final PhysicalObject physicalObject;
  final GraphqlObjectMetadata objectMetadata;
  final String typeName;
  final String? itemField;
  final String collectionField;
  final GraphqlCatalogIdentity identity;
}