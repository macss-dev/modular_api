export enum SqlReadCommandPurpose {
  Item = 'item',
  Collection = 'collection',
  RelationBatch = 'relation-batch',
  Count = 'count',
}

export class SqlParameter {
  readonly name: string;
  readonly type?: string;
  readonly value: unknown;

  constructor(options: { name: string; value: unknown; type?: string }) {
    this.name = options.name;
    this.value = options.value;
    this.type = options.type;
  }
}

export class SqlReadCommand {
  readonly engine: string;
  readonly sql: string;
  readonly parameters: readonly SqlParameter[];
  readonly purpose: SqlReadCommandPurpose;

  constructor(options: {
    engine: string;
    sql: string;
    parameters: readonly SqlParameter[];
    purpose: SqlReadCommandPurpose;
  }) {
    this.engine = options.engine;
    this.sql = options.sql;
    this.parameters = Object.freeze([...options.parameters]);
    this.purpose = options.purpose;
  }
}

export class ReadExecutionContext {
  readonly requestId?: string;
  readonly principal?: unknown;
  readonly tenantId?: string;
  readonly telemetry?: unknown;

  constructor(options: {
    requestId?: string;
    principal?: unknown;
    tenantId?: string;
    telemetry?: unknown;
  } = {}) {
    this.requestId = options.requestId;
    this.principal = options.principal;
    this.tenantId = options.tenantId;
    this.telemetry = options.telemetry;
  }
}

export class RowSet {
  readonly rows: readonly Readonly<Record<string, unknown>>[];
  readonly rowCount: number;

  constructor(options: { rows: readonly Readonly<Record<string, unknown>>[]; rowCount: number }) {
    this.rows = Object.freeze([...options.rows]);
    this.rowCount = options.rowCount;
  }

  static normalize(rawRows: Iterable<Record<PropertyKey, unknown>>): RowSet {
    const rows = Array.from(rawRows, (rawRow) => {
      const sortedEntries = Reflect.ownKeys(rawRow)
        .map((key) => [String(key), rawRow[key]] as const)
        .sort(([left], [right]) => left.localeCompare(right));
      const row: Record<string, unknown> = {};
      for (const [key, value] of sortedEntries) {
        row[key] = value;
      }
      return Object.freeze(row);
    });

    return new RowSet({ rows, rowCount: rows.length });
  }
}

export interface ReadExecutor {
  execute(command: SqlReadCommand, context: ReadExecutionContext): Promise<RowSet>;
  close(): Promise<void>;
}

export enum SqlFilterOperator {
  Eq = 'eq',
  Ne = 'ne',
  InList = 'inList',
  Lt = 'lt',
  Lte = 'lte',
  Gt = 'gt',
  Gte = 'gte',
  IsNull = 'isNull',
  Contains = 'contains',
  StartsWith = 'startsWith',
  EndsWith = 'endsWith',
}

export abstract class SqlFilterNode {}

export class SqlFilterCondition extends SqlFilterNode {
  readonly field: string;
  readonly operator: SqlFilterOperator;
  readonly value: unknown;

  constructor(options: { field: string; operator: SqlFilterOperator; value: unknown }) {
    super();
    this.field = options.field;
    this.operator = options.operator;
    this.value = options.value;
  }
}

export enum SqlFilterGroupKind {
  And = 'and',
  Or = 'or',
  Not = 'not',
}

export class SqlFilterGroup extends SqlFilterNode {
  readonly kind: SqlFilterGroupKind;
  readonly nodes: readonly SqlFilterNode[];

  private constructor(kind: SqlFilterGroupKind, nodes: readonly SqlFilterNode[]) {
    super();
    this.kind = kind;
    this.nodes = Object.freeze([...nodes]);
  }

  static and(nodes: readonly SqlFilterNode[]): SqlFilterGroup {
    return new SqlFilterGroup(SqlFilterGroupKind.And, nodes);
  }

  static or(nodes: readonly SqlFilterNode[]): SqlFilterGroup {
    return new SqlFilterGroup(SqlFilterGroupKind.Or, nodes);
  }

  static not(node: SqlFilterNode): SqlFilterGroup {
    return new SqlFilterGroup(SqlFilterGroupKind.Not, [node]);
  }
}

export enum SqlSortDirection {
  Asc = 'asc',
  Desc = 'desc',
}

export class SqlOrderByClause {
  readonly field: string;
  readonly direction: SqlSortDirection;

  constructor(options: { field: string; direction: SqlSortDirection }) {
    this.field = options.field;
    this.direction = options.direction;
  }
}

export class SqlPage {
  readonly limit: number;
  readonly offset: number;

  constructor(options: { limit: number; offset: number }) {
    this.limit = options.limit;
    this.offset = options.offset;
  }
}

export class SqlItemSelection {
  readonly objectId: string;
  readonly projectedFields: readonly string[];
  readonly key: Readonly<Record<string, unknown>>;

  constructor(options: {
    objectId: string;
    projectedFields: readonly string[];
    key: Readonly<Record<string, unknown>>;
  }) {
    this.objectId = options.objectId;
    this.projectedFields = Object.freeze([...options.projectedFields]);
    this.key = Object.freeze({ ...options.key });
  }
}

export class SqlCollectionSelection {
  readonly objectId: string;
  readonly projectedFields: readonly string[];
  readonly filter?: SqlFilterNode;
  readonly orderBy: readonly SqlOrderByClause[];
  readonly page?: SqlPage;

  constructor(options: {
    objectId: string;
    projectedFields: readonly string[];
    filter?: SqlFilterNode;
    orderBy?: readonly SqlOrderByClause[];
    page?: SqlPage;
  }) {
    this.objectId = options.objectId;
    this.projectedFields = Object.freeze([...options.projectedFields]);
    this.filter = options.filter;
    this.orderBy = Object.freeze([...(options.orderBy ?? [])]);
    this.page = options.page;
  }
}

export class SqlCountSelection {
  readonly objectId: string;
  readonly filter?: SqlFilterNode;

  constructor(options: { objectId: string; filter?: SqlFilterNode }) {
    this.objectId = options.objectId;
    this.filter = options.filter;
  }
}

export class SqlRelationBatchSelection {
  readonly sourceObjectId: string;
  readonly relationName: string;
  readonly projectedFields: readonly string[];
  readonly parentKeys: readonly Readonly<Record<string, unknown>>[];

  constructor(options: {
    sourceObjectId: string;
    relationName: string;
    projectedFields: readonly string[];
    parentKeys: readonly Readonly<Record<string, unknown>>[];
  }) {
    this.sourceObjectId = options.sourceObjectId;
    this.relationName = options.relationName;
    this.projectedFields = Object.freeze([...options.projectedFields]);
    this.parentKeys = Object.freeze(options.parentKeys.map((key) => Object.freeze({ ...key })));
  }
}