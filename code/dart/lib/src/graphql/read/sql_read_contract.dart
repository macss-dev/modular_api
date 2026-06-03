import 'dart:collection';

enum SqlReadCommandPurpose {
  item,
  collection,
  relationBatch,
  count,
}

final class SqlParameter {
  const SqlParameter({
    required this.name,
    required this.value,
    this.type,
  });

  final String name;
  final String? type;
  final Object? value;
}

final class SqlReadCommand {
  const SqlReadCommand({
    required this.engine,
    required this.sql,
    required this.parameters,
    required this.purpose,
  });

  final String engine;
  final String sql;
  final List<SqlParameter> parameters;
  final SqlReadCommandPurpose purpose;
}

final class ReadExecutionContext {
  const ReadExecutionContext({
    this.requestId,
    this.principal,
    this.tenantId,
    this.telemetry,
  });

  final String? requestId;
  final Object? principal;
  final String? tenantId;
  final Object? telemetry;
}

final class RowSet {
  const RowSet({required this.rows, required this.rowCount});

  final List<Map<String, Object?>> rows;
  final int rowCount;

  static RowSet normalize(Iterable<Map<Object?, Object?>> rawRows) {
    final rows = rawRows.map((rawRow) {
      final sortedEntries = rawRow.entries
          .map((entry) => MapEntry(entry.key.toString(), entry.value))
          .toList(growable: false)
        ..sort((left, right) => left.key.compareTo(right.key));
      final row = SplayTreeMap<String, Object?>();
      for (final entry in sortedEntries) {
        row[entry.key] = entry.value;
      }
      return Map<String, Object?>.unmodifiable(row);
    }).toList(growable: false);

    return RowSet(rows: rows, rowCount: rows.length);
  }
}

abstract class SqlReadExecutor {
  Future<RowSet> execute(SqlReadCommand command, ReadExecutionContext context);

  Future<void> close() async {}
}

enum SqlFilterOperator {
  eq,
  ne,
  inList,
  lt,
  lte,
  gt,
  gte,
  isNull,
  contains,
  startsWith,
  endsWith,
}

abstract class SqlFilterNode {
  const SqlFilterNode();
}

final class SqlFilterCondition extends SqlFilterNode {
  const SqlFilterCondition({
    required this.field,
    required this.operator,
    required this.value,
  });

  final String field;
  final SqlFilterOperator operator;
  final Object? value;
}

enum SqlFilterGroupKind {
  and,
  or,
  not,
}

final class SqlFilterGroup extends SqlFilterNode {
  const SqlFilterGroup._({required this.kind, required this.nodes});

  const SqlFilterGroup.and(List<SqlFilterNode> nodes)
      : this._(kind: SqlFilterGroupKind.and, nodes: nodes);

  const SqlFilterGroup.or(List<SqlFilterNode> nodes)
      : this._(kind: SqlFilterGroupKind.or, nodes: nodes);

  SqlFilterGroup.not(SqlFilterNode node)
      : kind = SqlFilterGroupKind.not,
        nodes = <SqlFilterNode>[node];

  final SqlFilterGroupKind kind;
  final List<SqlFilterNode> nodes;
}

enum SqlSortDirection {
  asc,
  desc,
}

final class SqlOrderByClause {
  const SqlOrderByClause({required this.field, required this.direction});

  final String field;
  final SqlSortDirection direction;
}

final class SqlPage {
  const SqlPage({required this.limit, required this.offset});

  final int limit;
  final int offset;
}

final class SqlItemSelection {
  const SqlItemSelection({
    required this.objectId,
    required this.projectedFields,
    required this.key,
  });

  final String objectId;
  final List<String> projectedFields;
  final Map<String, Object?> key;
}

final class SqlCollectionSelection {
  const SqlCollectionSelection({
    required this.objectId,
    required this.projectedFields,
    this.filter,
    this.orderBy = const <SqlOrderByClause>[],
    this.page,
  });

  final String objectId;
  final List<String> projectedFields;
  final SqlFilterNode? filter;
  final List<SqlOrderByClause> orderBy;
  final SqlPage? page;
}

final class SqlCountSelection {
  const SqlCountSelection({required this.objectId, this.filter});

  final String objectId;
  final SqlFilterNode? filter;
}

final class SqlRelationBatchSelection {
  const SqlRelationBatchSelection({
    required this.sourceObjectId,
    required this.relationName,
    required this.projectedFields,
    required this.parentKeys,
  });

  final String sourceObjectId;
  final String relationName;
  final List<String> projectedFields;
  final List<Map<String, Object?>> parentKeys;
}