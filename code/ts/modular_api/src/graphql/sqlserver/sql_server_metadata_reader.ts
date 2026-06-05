import {
  PhysicalObjectKind,
  type PhysicalCatalog,
  type PhysicalField,
  type PhysicalObject,
  type PhysicalRelationSeed,
} from './physical_model';
import { SqlServerConnectionSettings } from './sql_server_connection_settings';

type SqlServerConnectionConfig = {
  user: string;
  password: string;
  server: string;
  port: number;
  database: string;
  options: {
    encrypt: boolean;
    trustServerCertificate: boolean;
  };
};

type SqlServerRequestLike = {
  query<Row extends object>(query: string): Promise<{ recordset: Row[] }>;
};

type SqlServerConnectionPoolLike = {
  connect(): Promise<void>;
  close(): Promise<void>;
  request(): SqlServerRequestLike;
};

type SqlServerModuleLike = {
  ConnectionPool: new (config: SqlServerConnectionConfig) => SqlServerConnectionPoolLike;
};

type ObjectRow = {
  schema_name: string;
  object_name: string;
  object_kind: string;
};

type FieldRow = {
  schema_name: string;
  object_name: string;
  column_name: string;
  type_name: string;
  max_length: number;
  precision: number;
  scale: number;
  is_nullable: boolean | number;
};

type IdentityRow = {
  schema_name: string;
  object_name: string;
  column_name: string;
};

type RelationRow = {
  source_schema_name: string;
  source_object_name: string;
  constraint_name: string;
  source_column_name: string;
  target_schema_name: string;
  target_object_name: string;
  target_column_name: string;
};

type MutablePhysicalObject = {
  id: string;
  kind: PhysicalObjectKind;
  schemaName: string;
  objectName: string;
  identityFields: string[];
  fields: PhysicalField[];
  relations: PhysicalRelationSeed[];
};

type MutableRelation = {
  name: string;
  sourceObjectId: string;
  targetObjectId: string;
  sourceFields: string[];
  targetFields: string[];
};

export class SqlServerMetadataReader {
  private readonly connection: SqlServerConnectionSettings;
  private readonly sqlModuleLoader: () => SqlServerModuleLike;

  constructor(options: {
    connection: SqlServerConnectionSettings;
    sqlModule?: SqlServerModuleLike;
    sqlModuleLoader?: () => SqlServerModuleLike;
  }) {
    this.connection = options.connection;
    this.sqlModuleLoader =
      options.sqlModule == null
        ? (options.sqlModuleLoader ?? defaultSqlModuleLoader)
        : () => options.sqlModule as SqlServerModuleLike;
  }

  async introspect(options: { schemaNames?: Iterable<string> } = {}): Promise<PhysicalCatalog> {
    const normalizedSchemaNames = Array.from(options.schemaNames ?? []).sort();
    const sqlModule = loadSqlModule(this.sqlModuleLoader);
    const pool = new sqlModule.ConnectionPool(buildConnectionConfig(this.connection));

    await pool.connect();
    try {
      const objectsById = await loadObjects(pool, normalizedSchemaNames);
      await loadFields(pool, normalizedSchemaNames, objectsById);
      await loadIdentityFields(pool, normalizedSchemaNames, objectsById);
      await loadRelations(pool, normalizedSchemaNames, objectsById);

      return {
        objects: Array.from(objectsById.values())
          .map(buildPhysicalObject)
          .sort((left, right) => left.id.localeCompare(right.id)),
      };
    } finally {
      await pool.close();
    }
  }
}

async function loadObjects(
  pool: SqlServerConnectionPoolLike,
  schemaNames: readonly string[],
): Promise<Map<string, MutablePhysicalObject>> {
  const rows = await runMetadataQuery<ObjectRow>(
    pool,
    'SQL Server objects',
    `
SELECT
  s.name AS schema_name,
  o.name AS object_name,
  CASE o.type
    WHEN 'U' THEN 'table'
    WHEN 'V' THEN 'view'
  END AS object_kind
FROM sys.objects AS o
INNER JOIN sys.schemas AS s
  ON s.schema_id = o.schema_id
WHERE o.type IN ('U', 'V')${schemaFilterClause('s.name', schemaNames)}
ORDER BY s.name, o.name;
`,
  );

  const objectsById = new Map<string, MutablePhysicalObject>();
  for (const row of rows) {
    const id = `${row.schema_name}.${row.object_name}`;
    objectsById.set(id, {
      id,
      kind: parseObjectKind(row.object_kind),
      schemaName: row.schema_name,
      objectName: row.object_name,
      identityFields: [],
      fields: [],
      relations: [],
    });
  }

  return objectsById;
}

async function loadFields(
  pool: SqlServerConnectionPoolLike,
  schemaNames: readonly string[],
  objectsById: Map<string, MutablePhysicalObject>,
): Promise<void> {
  const rows = await runMetadataQuery<FieldRow>(
    pool,
    'SQL Server columns',
    `
SELECT
  s.name AS schema_name,
  o.name AS object_name,
  c.name AS column_name,
  TYPE_NAME(c.user_type_id) AS type_name,
  CAST(c.max_length AS INT) AS max_length,
  CAST(c.precision AS INT) AS precision,
  CAST(c.scale AS INT) AS scale,
  CAST(c.is_nullable AS INT) AS is_nullable
FROM sys.objects AS o
INNER JOIN sys.schemas AS s
  ON s.schema_id = o.schema_id
INNER JOIN sys.columns AS c
  ON c.object_id = o.object_id
WHERE o.type IN ('U', 'V')${schemaFilterClause('s.name', schemaNames)}
ORDER BY s.name, o.name, c.column_id;
`,
  );

  for (const row of rows) {
    const object = requireObject(objectsById, row.schema_name, row.object_name);
    object.fields.push({
      column: row.column_name,
      nativeType: formatNativeType({
        typeName: row.type_name,
        maxLength: row.max_length,
        precision: row.precision,
        scale: row.scale,
      }),
      nullable: Boolean(row.is_nullable),
    });
  }
}

async function loadIdentityFields(
  pool: SqlServerConnectionPoolLike,
  schemaNames: readonly string[],
  objectsById: Map<string, MutablePhysicalObject>,
): Promise<void> {
  const rows = await runMetadataQuery<IdentityRow>(
    pool,
    'SQL Server identity fields',
    `
SELECT
  s.name AS schema_name,
  o.name AS object_name,
  c.name AS column_name
FROM sys.objects AS o
INNER JOIN sys.schemas AS s
  ON s.schema_id = o.schema_id
INNER JOIN sys.key_constraints AS kc
  ON kc.parent_object_id = o.object_id
 AND kc.type = 'PK'
INNER JOIN sys.index_columns AS ic
  ON ic.object_id = kc.parent_object_id
 AND ic.index_id = kc.unique_index_id
INNER JOIN sys.columns AS c
  ON c.object_id = ic.object_id
 AND c.column_id = ic.column_id
WHERE o.type = 'U'${schemaFilterClause('s.name', schemaNames)}
ORDER BY s.name, o.name, ic.key_ordinal;
`,
  );

  for (const row of rows) {
    const object = requireObject(objectsById, row.schema_name, row.object_name);
    object.identityFields.push(row.column_name);
  }
}

async function loadRelations(
  pool: SqlServerConnectionPoolLike,
  schemaNames: readonly string[],
  objectsById: Map<string, MutablePhysicalObject>,
): Promise<void> {
  const rows = await runMetadataQuery<RelationRow>(
    pool,
    'SQL Server foreign keys',
    `
SELECT
  source_schema.name AS source_schema_name,
  source_object.name AS source_object_name,
  fk.name AS constraint_name,
  source_column.name AS source_column_name,
  target_schema.name AS target_schema_name,
  target_object.name AS target_object_name,
  target_column.name AS target_column_name
FROM sys.foreign_keys AS fk
INNER JOIN sys.foreign_key_columns AS fkc
  ON fkc.constraint_object_id = fk.object_id
INNER JOIN sys.objects AS source_object
  ON source_object.object_id = fk.parent_object_id
INNER JOIN sys.schemas AS source_schema
  ON source_schema.schema_id = source_object.schema_id
INNER JOIN sys.columns AS source_column
  ON source_column.object_id = source_object.object_id
 AND source_column.column_id = fkc.parent_column_id
INNER JOIN sys.objects AS target_object
  ON target_object.object_id = fk.referenced_object_id
INNER JOIN sys.schemas AS target_schema
  ON target_schema.schema_id = target_object.schema_id
INNER JOIN sys.columns AS target_column
  ON target_column.object_id = target_object.object_id
 AND target_column.column_id = fkc.referenced_column_id
WHERE source_object.type = 'U'${schemaFilterClause('source_schema.name', schemaNames)}
ORDER BY source_schema.name, source_object.name, fk.name, fkc.constraint_column_id;
`,
  );

  const relationsByKey = new Map<string, MutableRelation>();
  for (const row of rows) {
    const sourceObjectId = `${row.source_schema_name}.${row.source_object_name}`;
    const targetObjectId = `${row.target_schema_name}.${row.target_object_name}`;
    const relationKey = `${sourceObjectId}|${row.constraint_name}|${targetObjectId}`;
    const relation = relationsByKey.get(relationKey) ?? {
      name: row.constraint_name,
      sourceObjectId,
      targetObjectId,
      sourceFields: [],
      targetFields: [],
    };

    relation.sourceFields.push(row.source_column_name);
    relation.targetFields.push(row.target_column_name);
    relationsByKey.set(relationKey, relation);
  }

  for (const relation of relationsByKey.values()) {
    const sourceObject = objectsById.get(relation.sourceObjectId);
    if (!sourceObject) {
      throw new Error(`Missing source object for relation ${relation.name}: ${relation.sourceObjectId}`);
    }

    sourceObject.relations.push({
      name: relation.name,
      sourceObjectId: relation.sourceObjectId,
      targetObjectId: relation.targetObjectId,
      sourceFields: Object.freeze([...relation.sourceFields]),
      targetFields: Object.freeze([...relation.targetFields]),
    });
  }
}

async function runMetadataQuery<Row extends object>(
  pool: SqlServerConnectionPoolLike,
  label: string,
  query: string,
): Promise<Row[]> {
  try {
    const result = await pool.request().query<Row>(query);
    return result.recordset;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Failed to load ${label}: ${message}`);
  }
}

function buildConnectionConfig(connection: SqlServerConnectionSettings): SqlServerConnectionConfig {
  return {
    user: connection.username,
    password: connection.password,
    server: connection.host,
    port: connection.port,
    database: connection.database,
    options: {
      encrypt: false,
      trustServerCertificate: true,
    },
  };
}

function defaultSqlModuleLoader(): SqlServerModuleLike {
  try {
    const loaded = require('mssql') as SqlServerModuleLike & { default?: SqlServerModuleLike };
    return loaded.default ?? loaded;
  } catch (error) {
    throw toMissingSqlServerDriverError(error);
  }
}

function loadSqlModule(loader: () => SqlServerModuleLike): SqlServerModuleLike {
  try {
    return loader();
  } catch (error) {
    throw toMissingSqlServerDriverError(error);
  }
}

function toMissingSqlServerDriverError(error: unknown): Error {
  const message = error instanceof Error ? error.message : String(error);
  if (message.includes('SqlServerMetadataReader requires the optional "mssql" package.')) {
    return error instanceof Error ? error : new Error(message);
  }

  return new Error(
    'SqlServerMetadataReader requires the optional "mssql" package. Install it to use SQL Server introspection. ' +
      `Original error: ${message}`,
  );
}

function buildPhysicalObject(object: MutablePhysicalObject): PhysicalObject {
  return {
    id: object.id,
    kind: object.kind,
    schemaName: object.schemaName,
    objectName: object.objectName,
    identityFields: Object.freeze([...object.identityFields]),
    fields: Object.freeze([...object.fields]),
    relations: Object.freeze([...object.relations]),
  };
}

function requireObject(
  objectsById: Map<string, MutablePhysicalObject>,
  schemaName: string,
  objectName: string,
): MutablePhysicalObject {
  const objectId = `${schemaName}.${objectName}`;
  const object = objectsById.get(objectId);
  if (!object) {
    throw new Error(`Object not loaded before metadata expansion: ${objectId}`);
  }

  return object;
}

function parseObjectKind(value: string): PhysicalObjectKind {
  switch (value) {
    case PhysicalObjectKind.Table:
      return PhysicalObjectKind.Table;
    case PhysicalObjectKind.View:
      return PhysicalObjectKind.View;
    default:
      throw new Error(`Unsupported SQL Server object kind: ${value}`);
  }
}

function schemaFilterClause(column: string, schemaNames: readonly string[]): string {
  if (schemaNames.length === 0) {
    return '';
  }

  const values = schemaNames.map((schemaName) => `N'${schemaName.replace(/'/g, "''")}'`).join(', ');
  return ` AND ${column} IN (${values})`;
}

function formatNativeType(options: {
  typeName: string;
  maxLength: number;
  precision: number;
  scale: number;
}): string {
  switch (options.typeName.toLowerCase()) {
    case 'nvarchar':
    case 'nchar': {
      const length = options.maxLength === -1 ? 'max' : String(options.maxLength / 2);
      return `${options.typeName}(${length})`;
    }
    case 'varchar':
    case 'char':
    case 'varbinary':
    case 'binary': {
      const length = options.maxLength === -1 ? 'max' : String(options.maxLength);
      return `${options.typeName}(${length})`;
    }
    case 'decimal':
    case 'numeric':
      return `${options.typeName}(${options.precision},${options.scale})`;
    case 'datetime2':
    case 'datetimeoffset':
    case 'time':
      return `${options.typeName}(${options.scale})`;
    default:
      return options.typeName;
  }
}