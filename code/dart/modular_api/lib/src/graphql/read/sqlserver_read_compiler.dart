import 'package:modular_api/src/graphql/catalog/graphql_catalog_builder.dart';
import 'package:modular_api/src/graphql/read/sql_read_contract.dart';

final class SqlServerReadCompiler {
  const SqlServerReadCompiler();

  SqlReadCommand compileItem({
    required GraphqlCatalog catalog,
    required SqlItemSelection selection,
  }) {
    final object = _resolveObject(catalog, selection.objectId);
    final parameters = _SqlParameterBuilder();
    final selectList = _buildSelectList(object, selection.projectedFields);
    final whereClause = _compileKeyPredicate(
      object: object,
      publicKeyValues: selection.key,
      parameters: parameters,
    );

    return SqlReadCommand(
      engine: 'sqlserver',
      sql: 'SELECT TOP (1) $selectList FROM ${_tableRef(object)} WHERE $whereClause',
      parameters: parameters.build(),
      purpose: SqlReadCommandPurpose.item,
    );
  }

  SqlReadCommand compileCollection({
    required GraphqlCatalog catalog,
    required SqlCollectionSelection selection,
  }) {
    final object = _resolveObject(catalog, selection.objectId);
    final parameters = _SqlParameterBuilder();
    final sql = StringBuffer(
      'SELECT ${_buildSelectList(object, selection.projectedFields)} '
      'FROM ${_tableRef(object)}',
    );

    final whereClause = _compileFilter(
      object: object,
      filter: selection.filter,
      parameters: parameters,
    );
    if (whereClause != null) {
      sql.write(' WHERE $whereClause');
    }

    if (selection.orderBy.isNotEmpty) {
      sql.write(' ORDER BY ${_buildOrderBy(object, selection.orderBy)}');
    }

    if (selection.page case final SqlPage page) {
      final offsetName = parameters.add(page.offset, type: 'Int');
      final limitName = parameters.add(page.limit, type: 'Int');
      sql.write(' OFFSET @$offsetName ROWS FETCH NEXT @$limitName ROWS ONLY');
    }

    return SqlReadCommand(
      engine: 'sqlserver',
      sql: sql.toString(),
      parameters: parameters.build(),
      purpose: SqlReadCommandPurpose.collection,
    );
  }

  SqlReadCommand compileCount({
    required GraphqlCatalog catalog,
    required SqlCountSelection selection,
  }) {
    final object = _resolveObject(catalog, selection.objectId);
    final parameters = _SqlParameterBuilder();
    final sql = StringBuffer(
      'SELECT COUNT_BIG(1) AS [totalCount] FROM ${_tableRef(object)}',
    );
    final whereClause = _compileFilter(
      object: object,
      filter: selection.filter,
      parameters: parameters,
    );
    if (whereClause != null) {
      sql.write(' WHERE $whereClause');
    }

    return SqlReadCommand(
      engine: 'sqlserver',
      sql: sql.toString(),
      parameters: parameters.build(),
      purpose: SqlReadCommandPurpose.count,
    );
  }

  SqlReadCommand compileRelationBatch({
    required GraphqlCatalog catalog,
    required SqlRelationBatchSelection selection,
  }) {
    final sourceObject = _resolveObject(catalog, selection.sourceObjectId);
    final relation = sourceObject.relations.firstWhere(
      (candidate) => candidate.name == selection.relationName,
      orElse: () => throw ArgumentError(
        'Unknown relation ${selection.relationName} for ${selection.sourceObjectId}.',
      ),
    );
    final targetObject = _resolveObject(catalog, relation.target);
    final parameters = _SqlParameterBuilder();
    final selectList = _buildSelectList(targetObject, selection.projectedFields);
    final whereClause = _compileRelationBatchPredicate(
      sourceObject: sourceObject,
      targetObject: targetObject,
      relation: relation,
      parentKeys: selection.parentKeys,
      parameters: parameters,
    );

    return SqlReadCommand(
      engine: 'sqlserver',
      sql: 'SELECT $selectList FROM ${_tableRef(targetObject)} WHERE $whereClause',
      parameters: parameters.build(),
      purpose: SqlReadCommandPurpose.relationBatch,
    );
  }

  GraphqlPublishedObject _resolveObject(GraphqlCatalog catalog, String objectId) {
    return catalog.objects.firstWhere(
      (object) => object.id == objectId,
      orElse: () => throw ArgumentError('Unknown catalog object $objectId.'),
    );
  }

  String _tableRef(GraphqlPublishedObject object) {
    return '[${object.source.schemaName}].[${object.source.objectName}]';
  }

  String _buildSelectList(GraphqlPublishedObject object, List<String> publicFields) {
    return publicFields.map((publicField) {
      final field = _resolveFieldByPublicName(object, publicField);
      return '[${field.column}] AS [${field.publicName}]';
    }).join(', ');
  }

  String _compileKeyPredicate({
    required GraphqlPublishedObject object,
    required Map<String, Object?> publicKeyValues,
    required _SqlParameterBuilder parameters,
  }) {
    final clauses = <String>[];
    for (final keyColumn in object.identity.fields) {
      final field = _resolveFieldByColumn(object, keyColumn);
      if (!publicKeyValues.containsKey(field.publicName)) {
        throw ArgumentError('Missing key component ${field.publicName}.');
      }
      final parameterName = parameters.add(publicKeyValues[field.publicName], type: field.type);
      clauses.add('[${field.column}] = @$parameterName');
    }
    return clauses.join(' AND ');
  }

  String? _compileFilter({
    required GraphqlPublishedObject object,
    required SqlFilterNode? filter,
    required _SqlParameterBuilder parameters,
  }) {
    if (filter == null) {
      return null;
    }
    if (filter is SqlFilterCondition) {
      return _compileFilterCondition(object, filter, parameters);
    }
    if (filter is SqlFilterGroup) {
      if (filter.nodes.isEmpty) {
        return null;
      }
      if (filter.kind == SqlFilterGroupKind.not) {
        final child = _compileFilter(
          object: object,
          filter: filter.nodes.single,
          parameters: parameters,
        );
        return child == null ? null : 'NOT ($child)';
      }

      final compiledChildren = filter.nodes
          .map((node) => _compileFilter(object: object, filter: node, parameters: parameters))
          .whereType<String>()
          .toList(growable: false);
      if (compiledChildren.isEmpty) {
        return null;
      }
      final joiner = filter.kind == SqlFilterGroupKind.and ? ' AND ' : ' OR ';
      return '(${compiledChildren.join(joiner)})';
    }

    throw ArgumentError('Unsupported filter node ${filter.runtimeType}.');
  }

  String _compileFilterCondition(
    GraphqlPublishedObject object,
    SqlFilterCondition condition,
    _SqlParameterBuilder parameters,
  ) {
    final field = _resolveFieldByPublicName(object, condition.field);
    final columnRef = '[${field.column}]';

    if ((condition.operator == SqlFilterOperator.eq ||
            condition.operator == SqlFilterOperator.ne) &&
        condition.value == null) {
      throw ArgumentError('Use isNull instead of eq/ne with null for ${condition.field}.');
    }

    switch (condition.operator) {
      case SqlFilterOperator.eq:
        return '$columnRef = @${parameters.add(condition.value, type: field.type)}';
      case SqlFilterOperator.ne:
        return '$columnRef <> @${parameters.add(condition.value, type: field.type)}';
      case SqlFilterOperator.inList:
        final values = (condition.value as List<Object?>?) ?? const <Object?>[];
        if (values.isEmpty) {
          return '1 = 0';
        }
        final parameterRefs = values
            .map((value) => '@${parameters.add(value, type: field.type)}')
            .join(', ');
        return '$columnRef IN ($parameterRefs)';
      case SqlFilterOperator.lt:
        return '$columnRef < @${parameters.add(condition.value, type: field.type)}';
      case SqlFilterOperator.lte:
        return '$columnRef <= @${parameters.add(condition.value, type: field.type)}';
      case SqlFilterOperator.gt:
        return '$columnRef > @${parameters.add(condition.value, type: field.type)}';
      case SqlFilterOperator.gte:
        return '$columnRef >= @${parameters.add(condition.value, type: field.type)}';
      case SqlFilterOperator.isNull:
        final value = condition.value;
        if (value is! bool) {
          throw ArgumentError('isNull expects a boolean for ${condition.field}.');
        }
        return value ? '$columnRef IS NULL' : '$columnRef IS NOT NULL';
      case SqlFilterOperator.contains:
        return "$columnRef LIKE '%' + @${parameters.add(condition.value, type: field.type)} + '%'";
      case SqlFilterOperator.startsWith:
        return "$columnRef LIKE @${parameters.add(condition.value, type: field.type)} + '%'";
      case SqlFilterOperator.endsWith:
        return "$columnRef LIKE '%' + @${parameters.add(condition.value, type: field.type)}";
    }
  }

  String _buildOrderBy(
    GraphqlPublishedObject object,
    List<SqlOrderByClause> clauses,
  ) {
    return clauses.map((clause) {
      final field = _resolveFieldByPublicName(object, clause.field);
      final direction = clause.direction == SqlSortDirection.asc ? 'ASC' : 'DESC';
      return '[${field.column}] $direction';
    }).join(', ');
  }

  String _compileRelationBatchPredicate({
    required GraphqlPublishedObject sourceObject,
    required GraphqlPublishedObject targetObject,
    required GraphqlCatalogRelation relation,
    required List<Map<String, Object?>> parentKeys,
    required _SqlParameterBuilder parameters,
  }) {
    if (relation.targetFields.length == 1) {
      final sourceField = _resolveFieldByColumn(sourceObject, relation.sourceFields.single);
      final targetField = _resolveFieldByColumn(targetObject, relation.targetFields.single);
      final parameterRefs = parentKeys.map((parentKey) {
        if (!parentKey.containsKey(sourceField.publicName)) {
          throw ArgumentError(
            'Missing parent key component ${sourceField.publicName} for relation ${relation.name}.',
          );
        }
        return '@${parameters.add(parentKey[sourceField.publicName], type: targetField.type)}';
      }).join(', ');
      return '[${targetField.column}] IN ($parameterRefs)';
    }

    final disjunctions = <String>[];
    for (final parentKey in parentKeys) {
      final conjunctions = <String>[];
      for (var index = 0; index < relation.targetFields.length; index += 1) {
        final sourceField = _resolveFieldByColumn(sourceObject, relation.sourceFields[index]);
        final targetField = _resolveFieldByColumn(targetObject, relation.targetFields[index]);
        if (!parentKey.containsKey(sourceField.publicName)) {
          throw ArgumentError(
            'Missing parent key component ${sourceField.publicName} for relation ${relation.name}.',
          );
        }
        final parameterName = parameters.add(parentKey[sourceField.publicName], type: targetField.type);
        conjunctions.add('[${targetField.column}] = @$parameterName');
      }
      disjunctions.add('(${conjunctions.join(' AND ')})');
    }
    return disjunctions.join(' OR ');
  }

  GraphqlCatalogField _resolveFieldByPublicName(
    GraphqlPublishedObject object,
    String publicName,
  ) {
    return object.fields.firstWhere(
      (field) => field.publicName == publicName,
      orElse: () => throw ArgumentError(
        'Unknown public field $publicName for ${object.id}.',
      ),
    );
  }

  GraphqlCatalogField _resolveFieldByColumn(
    GraphqlPublishedObject object,
    String column,
  ) {
    return object.fields.firstWhere(
      (field) => field.column == column,
      orElse: () => throw ArgumentError(
        'Unknown source column $column for ${object.id}.',
      ),
    );
  }
}

final class SqlCatalogReadDispatcher {
  const SqlCatalogReadDispatcher({
    required this.compiler,
    required this.executor,
  });

  final SqlServerReadCompiler compiler;
  final SqlReadExecutor executor;

  Future<RowSet> readItem({
    required GraphqlCatalog catalog,
    required SqlItemSelection selection,
    required ReadExecutionContext context,
  }) {
    final command = compiler.compileItem(catalog: catalog, selection: selection);
    return executor.execute(command, context);
  }

  Future<RowSet> readCollection({
    required GraphqlCatalog catalog,
    required SqlCollectionSelection selection,
    required ReadExecutionContext context,
  }) {
    final command = compiler.compileCollection(catalog: catalog, selection: selection);
    return executor.execute(command, context);
  }

  Future<RowSet> readCount({
    required GraphqlCatalog catalog,
    required SqlCountSelection selection,
    required ReadExecutionContext context,
  }) {
    final command = compiler.compileCount(catalog: catalog, selection: selection);
    return executor.execute(command, context);
  }

  Future<RowSet> readRelationBatch({
    required GraphqlCatalog catalog,
    required SqlRelationBatchSelection selection,
    required ReadExecutionContext context,
  }) {
    final command = compiler.compileRelationBatch(catalog: catalog, selection: selection);
    return executor.execute(command, context);
  }
}

final class _SqlParameterBuilder {
  final List<SqlParameter> _parameters = <SqlParameter>[];

  String add(Object? value, {String? type}) {
    final name = 'p${_parameters.length}';
    _parameters.add(SqlParameter(name: name, type: type, value: value));
    return name;
  }

  List<SqlParameter> build() => List<SqlParameter>.unmodifiable(_parameters);
}