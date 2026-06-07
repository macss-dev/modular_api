import { createHash } from 'node:crypto';

import type {
  GraphqlFieldMetadata,
  GraphqlMetadataFile,
  GraphqlMetadataLimit,
  GraphqlObjectMetadata,
  GraphqlRelationMetadata,
} from '../metadata/graphql_metadata_parser';
import { PhysicalObjectKind, type PhysicalCatalog, type PhysicalField, type PhysicalObject } from '../sqlserver/physical_model';

export enum GraphqlCatalogBuildMode {
  Compile = 'compile',
  Runtime = 'runtime',
}

export enum GraphqlCatalogDiagnosticSeverity {
  Error = 'error',
  Warning = 'warning',
  Info = 'info',
}

export enum GraphqlCatalogOrigin {
  Inferred = 'inferred',
  Annotated = 'annotated',
}

export enum GraphqlCatalogIdentityMode {
  Single = 'single',
  Composite = 'composite',
  None = 'none',
}

export enum GraphqlCatalogFieldVisibility {
  Public = 'public',
  Hidden = 'hidden',
}

export enum GraphqlCatalogRelationCardinality {
  One = 'one',
  Many = 'many',
}

export enum GraphqlCatalogPaginationMode {
  Offset = 'offset',
  None = 'none',
}

export interface GraphqlCatalogDiagnostic {
  readonly severity: GraphqlCatalogDiagnosticSeverity;
  readonly code: string;
  readonly message: string;
  readonly objectId?: string;
  readonly field?: string;
}

export interface GraphqlCatalogProvider {
  readonly kind: string;
  readonly engine: string;
  readonly providerVersion: string;
}

export interface GraphqlCatalogBuild {
  readonly mode: GraphqlCatalogBuildMode;
  readonly sourceRoot: string;
  readonly sourceDigest: string;
}

export interface GraphqlCatalogGraphqlNames {
  readonly typeName: string;
  readonly collectionField: string;
  readonly itemField?: string;
}

export interface GraphqlCatalogSource {
  readonly schemaName: string;
  readonly objectName: string;
  readonly sourceFile?: string;
  readonly providerObjectId?: string;
}

export interface GraphqlCatalogIdentity {
  readonly mode: GraphqlCatalogIdentityMode;
  readonly fields: readonly string[];
  readonly origin: GraphqlCatalogOrigin;
}

export interface GraphqlCatalogField {
  readonly column: string;
  readonly publicName: string;
  readonly type: string;
  readonly nullable: boolean;
  readonly visibility: GraphqlCatalogFieldVisibility;
  readonly filterable: boolean;
  readonly sortable: boolean;
  readonly sensitive: boolean;
  readonly origin: GraphqlCatalogOrigin;
}

export interface GraphqlCatalogRelation {
  readonly name: string;
  readonly target: string;
  readonly cardinality: GraphqlCatalogRelationCardinality;
  readonly sourceFields: readonly string[];
  readonly targetFields: readonly string[];
  readonly origin: GraphqlCatalogOrigin;
}

export interface GraphqlCatalogPagination {
  readonly mode: GraphqlCatalogPaginationMode;
  readonly defaultLimit: number;
  readonly maxLimit: number;
}

export interface GraphqlCatalogCapabilities {
  readonly item: boolean;
  readonly collection: boolean;
  readonly filter: boolean;
  readonly sort: boolean;
  readonly pagination: GraphqlCatalogPagination;
}

export interface GraphqlPublishedObject {
  readonly id: string;
  readonly kind: PhysicalObjectKind;
  readonly readonly: boolean;
  readonly source: GraphqlCatalogSource;
  readonly graphql: GraphqlCatalogGraphqlNames;
  readonly identity: GraphqlCatalogIdentity;
  readonly fields: readonly GraphqlCatalogField[];
  readonly relations: readonly GraphqlCatalogRelation[];
  readonly capabilities: GraphqlCatalogCapabilities;
}

export interface GraphqlCatalog {
  readonly catalogVersion: string;
  readonly provider: GraphqlCatalogProvider;
  readonly build: GraphqlCatalogBuild;
  readonly objects: readonly GraphqlPublishedObject[];
  readonly diagnostics: readonly GraphqlCatalogDiagnostic[];
}

interface CatalogObjectContext {
  readonly physicalObject: PhysicalObject;
  readonly objectMetadata: GraphqlObjectMetadata;
  readonly typeName: string;
  readonly itemField?: string;
  readonly collectionField: string;
  readonly identity: GraphqlCatalogIdentity;
}

export class GraphqlCatalogNaming {
  static typeNameForObjectName(value: string): string {
    const tokens = GraphqlCatalogNaming.tokenize(value);
    if (tokens.length === 0) {
      return '';
    }

    return tokens.map((token) => GraphqlCatalogNaming.pascalToken(token)).join('');
  }

  static publicFieldNameForColumn(value: string): string {
    const tokens = GraphqlCatalogNaming.tokenize(value);
    if (tokens.length === 0) {
      return '';
    }

    const head = GraphqlCatalogNaming.pascalToken(tokens[0]!);
    const tail = tokens.slice(1).map((token) => GraphqlCatalogNaming.pascalToken(token)).join('');
    return GraphqlCatalogNaming.camelToken(head) + tail;
  }

  private static tokenize(value: string): string[] {
    const trimmed = value.trim();
    if (!trimmed) {
      return [];
    }

    const tokens: string[] = [];
    const segmentPattern = /[A-Za-z0-9]+/g;
    const wordPattern = /[A-Z]+(?:\d+)?(?=[A-Z][a-z]|$)|[A-Z]?[a-z]+\d*|\d+/g;
    const segments = trimmed.match(segmentPattern) ?? [];

    for (const segment of segments) {
      const words = segment.match(wordPattern) ?? [];
      for (const word of words) {
        if (word) {
          tokens.push(word);
        }
      }
    }

    return tokens;
  }

  private static pascalToken(token: string): string {
    if (!token) {
      return token;
    }
    if (/^\d+$/.test(token)) {
      return token;
    }

    const lower = token.toLowerCase();
    return `${lower[0]!.toUpperCase()}${lower.slice(1)}`;
  }

  private static camelToken(token: string): string {
    if (!token) {
      return token;
    }

    return `${token[0]!.toLowerCase()}${token.slice(1)}`;
  }
}

export class GraphqlCatalogBuilder {
  private readonly providerVersion: string;
  private readonly sourceRoot: string;
  private readonly buildMode: GraphqlCatalogBuildMode;
  private readonly engine: string;

  constructor(options: {
    providerVersion: string;
    sourceRoot: string;
    buildMode: GraphqlCatalogBuildMode;
    engine: string;
  }) {
    this.providerVersion = options.providerVersion;
    this.sourceRoot = options.sourceRoot;
    this.buildMode = options.buildMode;
    this.engine = options.engine;
  }

  build(options: {
    physicalCatalog: PhysicalCatalog;
    metadata: GraphqlMetadataFile;
  }): GraphqlCatalog {
    const diagnostics: GraphqlCatalogDiagnostic[] = [];
    const physicalObjectsById = new Map<string, PhysicalObject>(
      options.physicalCatalog.objects.map((object) => [object.id, object]),
    );

    const contexts = new Map<string, CatalogObjectContext>();
    const objectIds = Object.keys(options.metadata.objects).sort((left, right) => left.localeCompare(right));

    for (const objectId of objectIds) {
      const physicalObject = physicalObjectsById.get(objectId);
      if (!physicalObject) {
        diagnostics.push({
          severity: GraphqlCatalogDiagnosticSeverity.Error,
          code: 'metadata_object_unknown',
          message: 'Metadata references an object not present in the physical model.',
          objectId,
        });
        continue;
      }

      const objectMetadata = options.metadata.objects[objectId]!;
      const identity = this.resolveIdentity({
        physicalObject,
        objectMetadata,
        diagnostics,
      });
      const typeName = objectMetadata.name ?? GraphqlCatalogNaming.typeNameForObjectName(physicalObject.objectName);
      const itemField =
        identity.mode === GraphqlCatalogIdentityMode.None
          ? undefined
          : GraphqlCatalogNaming.publicFieldNameForColumn(typeName);
      const collectionField = `${GraphqlCatalogNaming.publicFieldNameForColumn(typeName)}List`;

      contexts.set(objectId, {
        physicalObject,
        objectMetadata,
        typeName,
        itemField,
        collectionField,
        identity,
      });
    }

    const objects = Array.from(contexts.keys())
      .map((objectId) =>
        this.buildObject({
          context: contexts.get(objectId)!,
          allContexts: contexts,
          defaultsLimit: options.metadata.defaultsLimit,
          diagnostics,
        }),
      )
      .sort((left, right) => left.id.localeCompare(right.id));

    this.detectDuplicateObjectNames(objects, diagnostics);
    const sortedDiagnostics = this.sortDiagnostics(diagnostics);

    const catalogWithoutDigest: GraphqlCatalog = {
      catalogVersion: '1.0.0',
      provider: {
        kind: 'sql',
        engine: this.engine,
        providerVersion: this.providerVersion,
      },
      build: {
        mode: this.buildMode,
        sourceRoot: this.sourceRoot,
        sourceDigest: '',
      },
      objects,
      diagnostics: sortedDiagnostics,
    };

    return {
      ...catalogWithoutDigest,
      build: {
        ...catalogWithoutDigest.build,
        sourceDigest: this.computeSourceDigest(catalogWithoutDigest),
      },
    };
  }

  private resolveIdentity(options: {
    physicalObject: PhysicalObject;
    objectMetadata: GraphqlObjectMetadata;
    diagnostics: GraphqlCatalogDiagnostic[];
  }): GraphqlCatalogIdentity {
    const annotatedKey = options.objectMetadata.key;
    if (annotatedKey && annotatedKey.length > 0) {
      return {
        mode: annotatedKey.length === 1 ? GraphqlCatalogIdentityMode.Single : GraphqlCatalogIdentityMode.Composite,
        fields: Object.freeze([...annotatedKey]),
        origin: GraphqlCatalogOrigin.Annotated,
      };
    }

    if (options.physicalObject.identityFields.length > 0) {
      return {
        mode:
          options.physicalObject.identityFields.length === 1
            ? GraphqlCatalogIdentityMode.Single
            : GraphqlCatalogIdentityMode.Composite,
        fields: Object.freeze([...options.physicalObject.identityFields]),
        origin: GraphqlCatalogOrigin.Inferred,
      };
    }

    if (options.physicalObject.kind === PhysicalObjectKind.View) {
      options.diagnostics.push({
        severity: GraphqlCatalogDiagnosticSeverity.Error,
        code: 'view_missing_identity',
        message: 'Published view requires explicit identity metadata.',
        objectId: options.physicalObject.id,
      });
    }

    return {
      mode: GraphqlCatalogIdentityMode.None,
      fields: Object.freeze([]),
      origin: GraphqlCatalogOrigin.Inferred,
    };
  }

  private buildObject(options: {
    context: CatalogObjectContext;
    allContexts: ReadonlyMap<string, CatalogObjectContext>;
    defaultsLimit?: GraphqlMetadataLimit;
    diagnostics: GraphqlCatalogDiagnostic[];
  }): GraphqlPublishedObject {
    const physicalObject = options.context.physicalObject;
    const objectMetadata = options.context.objectMetadata;

    const fields = [...physicalObject.fields]
      .map((field) =>
        this.buildField({
          objectId: physicalObject.id,
          physicalField: field,
          fieldMetadata: objectMetadata.fields[field.column],
          diagnostics: options.diagnostics,
        }),
      )
      .sort((left, right) => {
        const byPublicName = left.publicName.localeCompare(right.publicName);
        if (byPublicName !== 0) {
          return byPublicName;
        }
        return left.column.localeCompare(right.column);
      });

    this.detectDuplicateFieldNames(physicalObject.id, fields, options.diagnostics);

    const relations = this.buildRelations({
      context: options.context,
      allContexts: options.allContexts,
      diagnostics: options.diagnostics,
    });
    const pagination = this.resolvePagination(objectMetadata.limit, options.defaultsLimit);

    return {
      id: physicalObject.id,
      kind: physicalObject.kind,
      readonly: true,
      source: {
        schemaName: physicalObject.schemaName,
        objectName: physicalObject.objectName,
      },
      graphql: {
        typeName: options.context.typeName,
        collectionField: options.context.collectionField,
        itemField: options.context.itemField,
      },
      identity: options.context.identity,
      fields: Object.freeze(fields),
      relations,
      capabilities: {
        item: options.context.identity.mode !== GraphqlCatalogIdentityMode.None,
        collection: true,
        filter: fields.some(
          (field) => field.visibility === GraphqlCatalogFieldVisibility.Public && field.filterable,
        ),
        sort: fields.some(
          (field) => field.visibility === GraphqlCatalogFieldVisibility.Public && field.sortable,
        ),
        pagination,
      },
    };
  }

  private buildField(options: {
    objectId: string;
    physicalField: PhysicalField;
    fieldMetadata?: GraphqlFieldMetadata;
    diagnostics: GraphqlCatalogDiagnostic[];
  }): GraphqlCatalogField {
    const type = this.normalizeScalar({
      objectId: options.objectId,
      column: options.physicalField.column,
      nativeType: options.physicalField.nativeType,
      diagnostics: options.diagnostics,
    });
    const publicName = options.fieldMetadata?.name ?? GraphqlCatalogNaming.publicFieldNameForColumn(options.physicalField.column);
    const visibility = options.fieldMetadata?.hidden ? GraphqlCatalogFieldVisibility.Hidden : GraphqlCatalogFieldVisibility.Public;
    const filterable = visibility === GraphqlCatalogFieldVisibility.Public && !options.fieldMetadata?.noFilter && type !== 'Json';
    const sortable = visibility === GraphqlCatalogFieldVisibility.Public && !options.fieldMetadata?.noSort && type !== 'Json';

    return {
      column: options.physicalField.column,
      publicName,
      type,
      nullable: options.physicalField.nullable,
      visibility,
      filterable,
      sortable,
      sensitive: options.fieldMetadata?.sensitive ?? false,
      origin: options.fieldMetadata ? GraphqlCatalogOrigin.Annotated : GraphqlCatalogOrigin.Inferred,
    };
  }

  private buildRelations(options: {
    context: CatalogObjectContext;
    allContexts: ReadonlyMap<string, CatalogObjectContext>;
    diagnostics: GraphqlCatalogDiagnostic[];
  }): readonly GraphqlCatalogRelation[] {
    const relations: GraphqlCatalogRelation[] = [];
    const physicalObject = options.context.physicalObject;

    if (physicalObject.kind === PhysicalObjectKind.Table) {
      for (const relationSeed of physicalObject.relations) {
        const targetContext = options.allContexts.get(relationSeed.targetObjectId);
        if (!targetContext) {
          options.diagnostics.push({
            severity: GraphqlCatalogDiagnosticSeverity.Error,
            code: 'relation_target_unknown',
            message: 'Relation target is not published in the governed catalog.',
            objectId: physicalObject.id,
            field: relationSeed.name,
          });
          continue;
        }

        relations.push({
          name: GraphqlCatalogNaming.publicFieldNameForColumn(relationSeed.name),
          target: relationSeed.targetObjectId,
          cardinality: GraphqlCatalogRelationCardinality.One,
          sourceFields: Object.freeze([...relationSeed.sourceFields]),
          targetFields: Object.freeze([...relationSeed.targetFields]),
          origin: GraphqlCatalogOrigin.Inferred,
        });
      }
    } else {
      for (const relationMetadata of options.context.objectMetadata.relations) {
        const targetContext = options.allContexts.get(relationMetadata.target);
        if (!targetContext || targetContext.identity.mode === GraphqlCatalogIdentityMode.None) {
          options.diagnostics.push({
            severity: GraphqlCatalogDiagnosticSeverity.Error,
            code: 'relation_target_unknown',
            message: 'Relation target is not published with usable identity.',
            objectId: physicalObject.id,
            field: relationMetadata.name,
          });
          continue;
        }

        relations.push({
          name: relationMetadata.name,
          target: relationMetadata.target,
          cardinality:
            relationMetadata.cardinality === 'to-many'
              ? GraphqlCatalogRelationCardinality.Many
              : GraphqlCatalogRelationCardinality.One,
          sourceFields: Object.freeze([...relationMetadata.via]),
          targetFields: Object.freeze([...targetContext.identity.fields]),
          origin: GraphqlCatalogOrigin.Annotated,
        });
      }
    }

    relations.sort((left, right) => {
      const byName = left.name.localeCompare(right.name);
      if (byName !== 0) {
        return byName;
      }
      return left.target.localeCompare(right.target);
    });
    return Object.freeze(relations);
  }

  private resolvePagination(
    objectLimit: GraphqlMetadataLimit | undefined,
    defaultsLimit: GraphqlMetadataLimit | undefined,
  ): GraphqlCatalogPagination {
    const effectiveLimit = objectLimit ?? defaultsLimit ?? { defaultValue: 50, maxValue: 200 };
    return {
      mode: GraphqlCatalogPaginationMode.Offset,
      defaultLimit: effectiveLimit.defaultValue,
      maxLimit: effectiveLimit.maxValue,
    };
  }

  private normalizeScalar(options: {
    objectId: string;
    column: string;
    nativeType: string;
    diagnostics: GraphqlCatalogDiagnostic[];
  }): string {
    const normalized = options.nativeType.trim().toLowerCase();
    if (normalized.startsWith('bigint')) {
      return 'Long';
    }
    if (normalized.startsWith('int') || normalized.startsWith('smallint') || normalized.startsWith('tinyint')) {
      return 'Int';
    }
    if (
      normalized.startsWith('decimal') ||
      normalized.startsWith('numeric') ||
      normalized.startsWith('money') ||
      normalized.startsWith('smallmoney')
    ) {
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
    if (
      normalized.startsWith('datetime') ||
      normalized.startsWith('smalldatetime') ||
      normalized.startsWith('datetimeoffset')
    ) {
      return 'DateTime';
    }
    if (normalized.startsWith('uniqueidentifier')) {
      return 'Uuid';
    }
    if (normalized.startsWith('json')) {
      return 'Json';
    }
    if (
      normalized.startsWith('char') ||
      normalized.startsWith('nchar') ||
      normalized.startsWith('varchar') ||
      normalized.startsWith('nvarchar') ||
      normalized.startsWith('text') ||
      normalized.startsWith('ntext') ||
      normalized.startsWith('xml')
    ) {
      return 'String';
    }

    options.diagnostics.push({
      severity: GraphqlCatalogDiagnosticSeverity.Warning,
      code: 'unsupported_scalar',
      message: `Native type ${options.nativeType} is not mapped explicitly in the v1 scalar domain.`,
      objectId: options.objectId,
      field: options.column,
    });
    return 'String';
  }

  private detectDuplicateFieldNames(
    objectId: string,
    fields: readonly GraphqlCatalogField[],
    diagnostics: GraphqlCatalogDiagnostic[],
  ): void {
    const counts = new Map<string, number>();
    for (const field of fields) {
      counts.set(field.publicName, (counts.get(field.publicName) ?? 0) + 1);
    }

    const duplicates = Array.from(counts.entries())
      .filter(([, count]) => count > 1)
      .map(([publicName]) => publicName)
      .sort((left, right) => left.localeCompare(right));

    for (const publicName of duplicates) {
      diagnostics.push({
        severity: GraphqlCatalogDiagnosticSeverity.Error,
        code: 'duplicate_public_name',
        message: 'Multiple fields derive the same public GraphQL name.',
        objectId,
        field: publicName,
      });
    }
  }

  private detectDuplicateObjectNames(
    objects: readonly GraphqlPublishedObject[],
    diagnostics: GraphqlCatalogDiagnostic[],
  ): void {
    const typeCounts = new Map<string, number>();
    const itemCounts = new Map<string, number>();
    const collectionCounts = new Map<string, number>();

    for (const object of objects) {
      typeCounts.set(object.graphql.typeName, (typeCounts.get(object.graphql.typeName) ?? 0) + 1);
      collectionCounts.set(
        object.graphql.collectionField,
        (collectionCounts.get(object.graphql.collectionField) ?? 0) + 1,
      );
      if (object.graphql.itemField) {
        itemCounts.set(object.graphql.itemField, (itemCounts.get(object.graphql.itemField) ?? 0) + 1);
      }
    }

    for (const object of objects) {
      if ((typeCounts.get(object.graphql.typeName) ?? 0) > 1) {
        diagnostics.push({
          severity: GraphqlCatalogDiagnosticSeverity.Error,
          code: 'duplicate_public_name',
          message: 'Multiple objects derive the same GraphQL type name.',
          objectId: object.id,
          field: object.graphql.typeName,
        });
      }
      if ((collectionCounts.get(object.graphql.collectionField) ?? 0) > 1) {
        diagnostics.push({
          severity: GraphqlCatalogDiagnosticSeverity.Error,
          code: 'duplicate_public_name',
          message: 'Multiple objects derive the same collection field name.',
          objectId: object.id,
          field: object.graphql.collectionField,
        });
      }
      if (object.graphql.itemField && (itemCounts.get(object.graphql.itemField) ?? 0) > 1) {
        diagnostics.push({
          severity: GraphqlCatalogDiagnosticSeverity.Error,
          code: 'duplicate_public_name',
          message: 'Multiple objects derive the same item field name.',
          objectId: object.id,
          field: object.graphql.itemField,
        });
      }
    }
  }

  private sortDiagnostics(diagnostics: readonly GraphqlCatalogDiagnostic[]): readonly GraphqlCatalogDiagnostic[] {
    const severityRank: Record<GraphqlCatalogDiagnosticSeverity, number> = {
      [GraphqlCatalogDiagnosticSeverity.Error]: 0,
      [GraphqlCatalogDiagnosticSeverity.Warning]: 1,
      [GraphqlCatalogDiagnosticSeverity.Info]: 2,
    };

    return Object.freeze(
      [...diagnostics].sort((left, right) => {
        const bySeverity = severityRank[left.severity] - severityRank[right.severity];
        if (bySeverity !== 0) {
          return bySeverity;
        }

        const byCode = left.code.localeCompare(right.code);
        if (byCode !== 0) {
          return byCode;
        }

        const byObjectId = (left.objectId ?? '').localeCompare(right.objectId ?? '');
        if (byObjectId !== 0) {
          return byObjectId;
        }

        const byField = (left.field ?? '').localeCompare(right.field ?? '');
        if (byField !== 0) {
          return byField;
        }

        return left.message.localeCompare(right.message);
      }),
    );
  }

  private computeSourceDigest(catalog: GraphqlCatalog): string {
    const payload = {
      engine: this.engine,
      providerVersion: this.providerVersion,
      sourceRoot: this.sourceRoot,
      buildMode: this.buildMode,
      objects: catalog.objects.map((object) => this.objectDigestMap(object)),
    };
    const canonicalJson = JSON.stringify(this.canonicalize(payload));
    return createHash('sha256').update(canonicalJson).digest('hex');
  }

  private objectDigestMap(object: GraphqlPublishedObject): Record<string, unknown> {
    return {
      id: object.id,
      kind: object.kind,
      source: {
        schemaName: object.source.schemaName,
        objectName: object.source.objectName,
        sourceFile: object.source.sourceFile,
        providerObjectId: object.source.providerObjectId,
      },
      graphql: {
        typeName: object.graphql.typeName,
        collectionField: object.graphql.collectionField,
        itemField: object.graphql.itemField,
      },
      identity: {
        mode: object.identity.mode,
        fields: object.identity.fields,
        origin: object.identity.origin,
      },
      fields: object.fields.map((field) => ({
        column: field.column,
        publicName: field.publicName,
        type: field.type,
        nullable: field.nullable,
        visibility: field.visibility,
        filterable: field.filterable,
        sortable: field.sortable,
        sensitive: field.sensitive,
        origin: field.origin,
      })),
      relations: object.relations.map((relation) => ({
        name: relation.name,
        target: relation.target,
        cardinality: relation.cardinality,
        sourceFields: relation.sourceFields,
        targetFields: relation.targetFields,
        origin: relation.origin,
      })),
      capabilities: {
        item: object.capabilities.item,
        collection: object.capabilities.collection,
        filter: object.capabilities.filter,
        sort: object.capabilities.sort,
        pagination: {
          mode: object.capabilities.pagination.mode,
          defaultLimit: object.capabilities.pagination.defaultLimit,
          maxLimit: object.capabilities.pagination.maxLimit,
        },
      },
    };
  }

  private canonicalize(value: unknown): unknown {
    if (Array.isArray(value)) {
      return value.map((entry) => this.canonicalize(entry));
    }
    if (value && typeof value === 'object') {
      const sorted: Record<string, unknown> = {};
      for (const key of Object.keys(value).sort((left, right) => left.localeCompare(right))) {
        sorted[key] = this.canonicalize((value as Record<string, unknown>)[key]);
      }
      return sorted;
    }
    return value;
  }
}