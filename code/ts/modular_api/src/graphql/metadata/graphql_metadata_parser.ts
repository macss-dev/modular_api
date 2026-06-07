import JSON5 from 'json5';

import { PhysicalObjectKind, type PhysicalCatalog, type PhysicalObject } from '../sqlserver/physical_model';

export enum GraphqlMetadataSeverity {
  Error = 'error',
  Warning = 'warning',
}

export interface GraphqlMetadataDiagnostic {
  readonly severity: GraphqlMetadataSeverity;
  readonly code: string;
  readonly message: string;
  readonly objectId?: string;
  readonly field?: string;
}

export interface GraphqlMetadataLimit {
  readonly defaultValue: number;
  readonly maxValue: number;
}

export interface GraphqlFieldMetadata {
  readonly hidden: boolean;
  readonly sensitive: boolean;
  readonly noFilter: boolean;
  readonly noSort: boolean;
  readonly name?: string;
}

export interface GraphqlRelationMetadata {
  readonly name: string;
  readonly cardinality: string;
  readonly target: string;
  readonly via: readonly string[];
}

export interface GraphqlObjectMetadata {
  readonly publish: true;
  readonly name?: string;
  readonly key?: readonly string[];
  readonly fields: Readonly<Record<string, GraphqlFieldMetadata>>;
  readonly relations: readonly GraphqlRelationMetadata[];
  readonly limit?: GraphqlMetadataLimit;
}

export interface GraphqlMetadataFile {
  readonly schema?: string;
  readonly version: number;
  readonly defaultsLimit?: GraphqlMetadataLimit;
  readonly objects: Readonly<Record<string, GraphqlObjectMetadata>>;
}

export interface GraphqlMetadataParseResult {
  readonly metadata: GraphqlMetadataFile | null;
  readonly diagnostics: readonly GraphqlMetadataDiagnostic[];
}

export class GraphqlMetadataParser {
  parse(options: { rawJsonc: string; physicalCatalog: PhysicalCatalog }): GraphqlMetadataParseResult {
    const diagnostics: GraphqlMetadataDiagnostic[] = [];
    const physicalObjectsById = new Map<string, PhysicalObject>(
      options.physicalCatalog.objects.map((object) => [object.id, object]),
    );

    let decoded: unknown;
    try {
      decoded = JSON5.parse(options.rawJsonc);
    } catch (error) {
      return {
        metadata: null,
        diagnostics: [
          {
            severity: GraphqlMetadataSeverity.Error,
            code: 'metadata_invalid_shape',
            message: `Failed to parse graphql.metadata.jsonc: ${error instanceof Error ? error.message : String(error)}`,
          },
        ],
      };
    }

    if (!isRecord(decoded)) {
      return {
        metadata: null,
        diagnostics: [
          {
            severity: GraphqlMetadataSeverity.Error,
            code: 'metadata_invalid_shape',
            message: 'Top-level metadata value must be an object.',
          },
        ],
      };
    }

    const root = { ...decoded };
    collectUnknownKeys({
      map: root,
      allowedKeys: new Set(['$schema', 'version', 'defaults', 'objects']),
      diagnostics,
    });

    const version = root.version;
    if (!Number.isInteger(version) || version !== 1) {
      diagnostics.push({
        severity: GraphqlMetadataSeverity.Error,
        code: 'metadata_invalid_shape',
        message: 'Metadata version must be the integer 1.',
        field: 'version',
      });
    }

    const objectsValue = root.objects;
    if (!isRecord(objectsValue)) {
      diagnostics.push({
        severity: GraphqlMetadataSeverity.Error,
        code: 'metadata_invalid_shape',
        message: 'Metadata objects must be an object keyed by schema.object.',
        field: 'objects',
      });
      return {
        metadata: null,
        diagnostics: sortDiagnostics(diagnostics),
      };
    }

    const defaultsLimit = parseLimit({
      scopeName: 'defaults.limit',
      value: readOptionalChildMap(root, 'defaults')?.limit,
      diagnostics,
    });

    const objects: Record<string, GraphqlObjectMetadata> = {};
    const objectIds = Object.keys(objectsValue).sort((left, right) => left.localeCompare(right));

    for (const objectId of objectIds) {
      const objectValue = objectsValue[objectId];
      if (!isRecord(objectValue)) {
        diagnostics.push({
          severity: GraphqlMetadataSeverity.Error,
          code: 'metadata_invalid_shape',
          message: 'Metadata object entry must be an object.',
          objectId,
        });
        continue;
      }

      collectUnknownKeys({
        map: objectValue,
        allowedKeys: new Set(['publish', 'name', 'key', 'fields', 'relations', 'limit']),
        diagnostics,
        objectId,
      });

      if (objectValue.publish !== true) {
        diagnostics.push({
          severity: GraphqlMetadataSeverity.Error,
          code: 'metadata_invalid_shape',
          message: 'Object metadata entry must declare publish: true.',
          objectId,
          field: 'publish',
        });
        continue;
      }

      const metadata: GraphqlObjectMetadata = {
        publish: true,
        name: readOptionalString(objectValue, 'name', diagnostics, objectId),
        key: readOptionalStringList(objectValue, 'key', diagnostics, objectId),
        fields: parseFields(objectValue.fields, diagnostics, objectId),
        relations: parseRelations(objectValue.relations, diagnostics, objectId),
        limit: parseLimit({
          scopeName: `${objectId}.limit`,
          value: objectValue.limit,
          diagnostics,
          objectId,
        }),
      };
      objects[objectId] = metadata;

      const physicalObject = physicalObjectsById.get(objectId);
      if (!physicalObject) {
        diagnostics.push({
          severity: GraphqlMetadataSeverity.Error,
          code: 'metadata_object_unknown',
          message: 'Metadata references an object not present in the physical model.',
          objectId,
        });
        continue;
      }

      if (physicalObject.kind === PhysicalObjectKind.View && (!metadata.key || metadata.key.length === 0)) {
        diagnostics.push({
          severity: GraphqlMetadataSeverity.Error,
          code: 'view_missing_identity',
          message: 'Published view requires explicit key metadata in v1.',
          objectId,
        });
      }
    }

    return {
      metadata: {
        schema: typeof root.$schema === 'string' ? root.$schema : undefined,
        version: typeof version === 'number' && Number.isInteger(version) ? version : 0,
        defaultsLimit,
        objects,
      },
      diagnostics: sortDiagnostics(diagnostics),
    };
  }
}

function collectUnknownKeys(options: {
  map: Record<string, unknown>;
  allowedKeys: ReadonlySet<string>;
  diagnostics: GraphqlMetadataDiagnostic[];
  objectId?: string;
}): void {
  const unknownKeys = Object.keys(options.map)
    .filter((key) => !options.allowedKeys.has(key))
    .sort((left, right) => left.localeCompare(right));

  for (const key of unknownKeys) {
    options.diagnostics.push({
      severity: GraphqlMetadataSeverity.Warning,
      code: 'metadata_unknown_key',
      message: `Unknown metadata key: ${key}`,
      objectId: options.objectId,
      field: key,
    });
  }
}

function readOptionalChildMap(parent: Record<string, unknown>, key: string): Record<string, unknown> | undefined {
  const value = parent[key];
  return isRecord(value) ? value : undefined;
}

function readOptionalString(
  map: Record<string, unknown>,
  key: string,
  diagnostics: GraphqlMetadataDiagnostic[],
  objectId?: string,
): string | undefined {
  const value = map[key];
  if (value == null) {
    return undefined;
  }
  if (typeof value === 'string') {
    return value;
  }

  diagnostics.push({
    severity: GraphqlMetadataSeverity.Error,
    code: 'metadata_invalid_shape',
    message: 'Metadata field must be a string.',
    objectId,
    field: key,
  });
  return undefined;
}

function readOptionalStringList(
  map: Record<string, unknown>,
  key: string,
  diagnostics: GraphqlMetadataDiagnostic[],
  objectId?: string,
): readonly string[] | undefined {
  const value = map[key];
  if (value == null) {
    return undefined;
  }
  if (!Array.isArray(value) || value.some((item) => typeof item !== 'string')) {
    diagnostics.push({
      severity: GraphqlMetadataSeverity.Error,
      code: 'metadata_invalid_shape',
      message: 'Metadata field must be an array of strings.',
      objectId,
      field: key,
    });
    return undefined;
  }

  return Object.freeze([...value]);
}

function parseFields(
  value: unknown,
  diagnostics: GraphqlMetadataDiagnostic[],
  objectId: string,
): Readonly<Record<string, GraphqlFieldMetadata>> {
  if (value == null) {
    return Object.freeze({});
  }
  if (!isRecord(value)) {
    diagnostics.push({
      severity: GraphqlMetadataSeverity.Error,
      code: 'metadata_invalid_shape',
      message: 'fields must be an object keyed by column name.',
      objectId,
      field: 'fields',
    });
    return Object.freeze({});
  }

  const fields: Record<string, GraphqlFieldMetadata> = {};
  for (const fieldName of Object.keys(value).sort((left, right) => left.localeCompare(right))) {
    const fieldValue = value[fieldName];
    if (!isRecord(fieldValue)) {
      diagnostics.push({
        severity: GraphqlMetadataSeverity.Error,
        code: 'metadata_invalid_shape',
        message: 'Field metadata entry must be an object.',
        objectId,
        field: fieldName,
      });
      continue;
    }

    collectUnknownKeys({
      map: fieldValue,
      allowedKeys: new Set(['hidden', 'sensitive', 'noFilter', 'noSort', 'name']),
      diagnostics,
      objectId,
    });

    fields[fieldName] = {
      hidden: readOptionalBool(fieldValue, 'hidden', diagnostics, objectId, fieldName),
      sensitive: readOptionalBool(fieldValue, 'sensitive', diagnostics, objectId, fieldName),
      noFilter: readOptionalBool(fieldValue, 'noFilter', diagnostics, objectId, fieldName),
      noSort: readOptionalBool(fieldValue, 'noSort', diagnostics, objectId, fieldName),
      name: readOptionalString(fieldValue, 'name', diagnostics, objectId),
    };
  }

  return Object.freeze(fields);
}

function parseRelations(
  value: unknown,
  diagnostics: GraphqlMetadataDiagnostic[],
  objectId: string,
): readonly GraphqlRelationMetadata[] {
  if (value == null) {
    return Object.freeze([]);
  }
  if (!Array.isArray(value)) {
    diagnostics.push({
      severity: GraphqlMetadataSeverity.Error,
      code: 'metadata_invalid_shape',
      message: 'relations must be an array.',
      objectId,
      field: 'relations',
    });
    return Object.freeze([]);
  }

  const relations: GraphqlRelationMetadata[] = [];
  for (const entry of value) {
    if (!isRecord(entry)) {
      diagnostics.push({
        severity: GraphqlMetadataSeverity.Error,
        code: 'metadata_invalid_shape',
        message: 'Relation entry must be an object.',
        objectId,
        field: 'relations',
      });
      continue;
    }

    collectUnknownKeys({
      map: entry,
      allowedKeys: new Set(['name', 'cardinality', 'target', 'via']),
      diagnostics,
      objectId,
    });

    relations.push({
      name: entry.name == null ? '' : String(entry.name),
      cardinality: entry.cardinality == null ? '' : String(entry.cardinality),
      target: entry.target == null ? '' : String(entry.target),
      via: Array.isArray(entry.via) ? Object.freeze(entry.via.map((item) => String(item))) : Object.freeze([]),
    });
  }

  return Object.freeze(relations);
}

function parseLimit(options: {
  scopeName: string;
  value: unknown;
  diagnostics: GraphqlMetadataDiagnostic[];
  objectId?: string;
}): GraphqlMetadataLimit | undefined {
  if (options.value == null) {
    return undefined;
  }
  if (!isRecord(options.value)) {
    options.diagnostics.push({
      severity: GraphqlMetadataSeverity.Error,
      code: 'metadata_invalid_shape',
      message: 'Limit metadata must be an object.',
      objectId: options.objectId,
      field: options.scopeName,
    });
    return undefined;
  }

  const defaultValue = options.value.default;
  const maxValue = options.value.max;
  if (
    typeof defaultValue !== 'number' ||
    !Number.isInteger(defaultValue) ||
    typeof maxValue !== 'number' ||
    !Number.isInteger(maxValue)
  ) {
    options.diagnostics.push({
      severity: GraphqlMetadataSeverity.Error,
      code: 'metadata_invalid_shape',
      message: 'Limit metadata requires integer default and max values.',
      objectId: options.objectId,
      field: options.scopeName,
    });
    return undefined;
  }
  if (defaultValue > maxValue) {
    options.diagnostics.push({
      severity: GraphqlMetadataSeverity.Error,
      code: 'metadata_invalid_shape',
      message: 'Limit metadata requires default <= max.',
      objectId: options.objectId,
      field: options.scopeName,
    });
  }

  return { defaultValue, maxValue };
}

function readOptionalBool(
  map: Record<string, unknown>,
  key: string,
  diagnostics: GraphqlMetadataDiagnostic[],
  objectId: string | undefined,
  field: string,
): boolean {
  const value = map[key];
  if (value == null) {
    return false;
  }
  if (typeof value === 'boolean') {
    return value;
  }

  diagnostics.push({
    severity: GraphqlMetadataSeverity.Error,
    code: 'metadata_invalid_shape',
    message: 'Metadata flag must be a boolean.',
    objectId,
    field,
  });
  return false;
}

function sortDiagnostics(diagnostics: GraphqlMetadataDiagnostic[]): readonly GraphqlMetadataDiagnostic[] {
  const severityRank: Record<GraphqlMetadataSeverity, number> = {
    [GraphqlMetadataSeverity.Error]: 0,
    [GraphqlMetadataSeverity.Warning]: 1,
  };

  return Object.freeze(
    [...diagnostics].sort((left, right) => {
      const severityOrder = severityRank[left.severity] - severityRank[right.severity];
      if (severityOrder !== 0) {
        return severityOrder;
      }

      const codeOrder = left.code.localeCompare(right.code);
      if (codeOrder !== 0) {
        return codeOrder;
      }

      const objectOrder = (left.objectId ?? '').localeCompare(right.objectId ?? '');
      if (objectOrder !== 0) {
        return objectOrder;
      }

      const fieldOrder = (left.field ?? '').localeCompare(right.field ?? '');
      if (fieldOrder !== 0) {
        return fieldOrder;
      }

      return left.message.localeCompare(right.message);
    }),
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}