import { access, mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import {
  GraphqlCatalogBuildMode,
  GraphqlCatalogDiagnosticSeverity,
  GraphqlCatalogFieldVisibility,
  GraphqlCatalogIdentityMode,
  GraphqlCatalogOrigin,
  GraphqlCatalogPaginationMode,
  GraphqlCatalogRelationCardinality,
  type GraphqlCatalog,
  type GraphqlCatalogDiagnostic,
  type GraphqlPublishedObject,
} from '../catalog/graphql_catalog_builder';
import { GraphqlSchemaSdlGenerator } from '../schema/graphql_schema_sdl_generator';
import { PhysicalObjectKind } from '../sqlserver/physical_model';
import type { GraphqlOptions, GraphqlSourceDigestFactory } from './graphql_runtime_options';

const CATALOG_FILE_NAME = 'catalog.json';
const CATALOG_LOCK_FILE_NAME = 'catalog.lock';
const DIAGNOSTICS_FILE_NAME = 'diagnostics.json';
const SCHEMA_FILE_NAME = 'schema.graphql';

const DIAGNOSTIC_SEVERITY_ORDER: Record<GraphqlCatalogDiagnosticSeverity, number> = {
  [GraphqlCatalogDiagnosticSeverity.Error]: 0,
  [GraphqlCatalogDiagnosticSeverity.Warning]: 1,
  [GraphqlCatalogDiagnosticSeverity.Info]: 2,
};

export class GraphqlArtifactBundle {
  readonly catalogJson: string;
  readonly catalogLockJson: string;
  readonly diagnosticsJson: string;
  readonly schemaGraphql: string;

  constructor(options: {
    catalogJson: string;
    catalogLockJson: string;
    diagnosticsJson: string;
    schemaGraphql: string;
  }) {
    this.catalogJson = options.catalogJson;
    this.catalogLockJson = options.catalogLockJson;
    this.diagnosticsJson = options.diagnosticsJson;
    this.schemaGraphql = options.schemaGraphql;
  }

  async writeToDirectory(outputDirectory: string): Promise<void> {
    await mkdir(outputDirectory, { recursive: true });
    await writeFile(artifactPath(outputDirectory, CATALOG_FILE_NAME), this.catalogJson, 'utf8');
    await writeFile(artifactPath(outputDirectory, CATALOG_LOCK_FILE_NAME), this.catalogLockJson, 'utf8');
    await writeFile(artifactPath(outputDirectory, DIAGNOSTICS_FILE_NAME), this.diagnosticsJson, 'utf8');
    await writeFile(artifactPath(outputDirectory, SCHEMA_FILE_NAME), this.schemaGraphql, 'utf8');
  }
}

export class GraphqlArtifactCompileError extends Error {
  readonly bundle: GraphqlArtifactBundle;

  constructor(options: { message: string; bundle: GraphqlArtifactBundle }) {
    super(options.message);
    this.name = 'GraphqlArtifactCompileError';
    this.bundle = options.bundle;
  }
}

export class GraphqlArtifactLoadError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'GraphqlArtifactLoadError';
  }
}

export class GraphqlArtifactCompiler {
  readonly catalogFactory: GraphqlOptions['catalogFactory'];
  readonly sdlFactory: GraphqlOptions['sdlFactory'];

  constructor(options: {
    catalogFactory: GraphqlOptions['catalogFactory'];
    sdlFactory?: GraphqlOptions['sdlFactory'];
  }) {
    this.catalogFactory = options.catalogFactory;
    this.sdlFactory = options.sdlFactory ?? ((catalog) => new GraphqlSchemaSdlGenerator().generate(catalog));
  }

  async compile(): Promise<GraphqlArtifactBundle> {
    const rawCatalog = await this.catalogFactory();
    const catalog = canonicalCatalog(rawCatalog);
    const bundle = new GraphqlArtifactBundle({
      catalogJson: prettyJson(catalogToJson(catalog)),
      catalogLockJson: prettyJson(catalogLockToJson(catalog)),
      diagnosticsJson: prettyJson(diagnosticsToJson(catalog.diagnostics)),
      schemaGraphql: normalizedSchema(this.sdlFactory(catalog)),
    });

    const blockingDiagnostics = catalog.diagnostics.filter(
      (diagnostic) => diagnostic.severity === GraphqlCatalogDiagnosticSeverity.Error,
    );
    if (blockingDiagnostics.length > 0) {
      throw new GraphqlArtifactCompileError({
        message: 'GraphQL artifact compilation failed because blocking diagnostics exist.',
        bundle,
      });
    }

    return bundle;
  }

  async writeToDirectory(outputDirectory: string): Promise<GraphqlArtifactBundle> {
    try {
      const bundle = await this.compile();
      await bundle.writeToDirectory(outputDirectory);
      return bundle;
    } catch (error) {
      if (error instanceof GraphqlArtifactCompileError) {
        await error.bundle.writeToDirectory(outputDirectory);
      }
      throw error;
    }
  }
}

export async function tryLoadGraphqlCatalogArtifacts(options: {
  artifactDirectory: string;
  currentSourceDigest: string;
}): Promise<GraphqlCatalog | undefined> {
  const catalogPath = artifactPath(options.artifactDirectory, CATALOG_FILE_NAME);
  const lockPath = artifactPath(options.artifactDirectory, CATALOG_LOCK_FILE_NAME);

  if (!(await fileExists(catalogPath)) || !(await fileExists(lockPath))) {
    return undefined;
  }

  const lockJson = parseJsonObject(
    await readFile(lockPath, 'utf8'),
    'catalog.lock must be a JSON object.',
  );
  const lock = catalogLockFromJson(lockJson);
  if (lock.sourceDigest !== options.currentSourceDigest) {
    return undefined;
  }

  const catalogJson = parseJsonObject(
    await readFile(catalogPath, 'utf8'),
    'catalog.json must be a JSON object.',
  );
  const catalog = canonicalCatalog(catalogFromJson(catalogJson));
  if (
    catalog.catalogVersion !== lock.catalogVersion ||
    catalog.build.sourceDigest !== lock.sourceDigest ||
    catalog.provider.providerVersion !== lock.providerVersion
  ) {
    return undefined;
  }

  return catalog;
}

export async function resolveCatalogFromArtifactsOrSource(options: {
  graphql: GraphqlOptions;
}): Promise<GraphqlCatalog> {
  const artifactDirectory = options.graphql.artifactDirectory;
  const sourceDigestFactory = options.graphql.sourceDigestFactory;
  if (artifactDirectory && sourceDigestFactory) {
    try {
      const currentSourceDigest = await Promise.resolve(sourceDigestFactory());
      const prebuiltCatalog = await tryLoadGraphqlCatalogArtifacts({
        artifactDirectory,
        currentSourceDigest,
      });
      if (prebuiltCatalog) {
        return prebuiltCatalog;
      }
    } catch (error) {
      throw new GraphqlArtifactLoadError(String(error instanceof Error ? error.message : error));
    }
  }

  return options.graphql.catalogFactory();
}

function artifactPath(directory: string, fileName: string): string {
  return join(directory, fileName);
}

async function fileExists(filePath: string): Promise<boolean> {
  try {
    await access(filePath);
    return true;
  } catch {
    return false;
  }
}

function prettyJson(payload: unknown): string {
  return `${JSON.stringify(canonicalize(payload), undefined, 2)}\n`;
}

function normalizedSchema(schema: string): string {
  return schema.endsWith('\n') ? schema : `${schema}\n`;
}

function canonicalCatalog(catalog: GraphqlCatalog): GraphqlCatalog {
  return {
    catalogVersion: catalog.catalogVersion,
    provider: catalog.provider,
    build: catalog.build,
    objects: [...catalog.objects].map(canonicalObject).sort((left, right) => left.id.localeCompare(right.id)),
    diagnostics: [...catalog.diagnostics].sort(compareDiagnostics),
  };
}

function canonicalObject(object: GraphqlPublishedObject): GraphqlPublishedObject {
  return {
    ...object,
    fields: [...object.fields].sort((left, right) => {
      const publicName = left.publicName.localeCompare(right.publicName);
      return publicName !== 0 ? publicName : left.column.localeCompare(right.column);
    }),
    relations: [...object.relations].sort((left, right) => {
      const name = left.name.localeCompare(right.name);
      return name !== 0 ? name : left.target.localeCompare(right.target);
    }),
  };
}

function compareDiagnostics(left: GraphqlCatalogDiagnostic, right: GraphqlCatalogDiagnostic): number {
  const severity = DIAGNOSTIC_SEVERITY_ORDER[left.severity] - DIAGNOSTIC_SEVERITY_ORDER[right.severity];
  if (severity !== 0) {
    return severity;
  }
  const code = left.code.localeCompare(right.code);
  if (code !== 0) {
    return code;
  }
  const objectId = (left.objectId ?? '').localeCompare(right.objectId ?? '');
  if (objectId !== 0) {
    return objectId;
  }
  const field = (left.field ?? '').localeCompare(right.field ?? '');
  if (field !== 0) {
    return field;
  }
  return left.message.localeCompare(right.message);
}

function catalogToJson(catalog: GraphqlCatalog): Record<string, unknown> {
  return {
    catalogVersion: catalog.catalogVersion,
    provider: {
      kind: catalog.provider.kind,
      engine: catalog.provider.engine,
      providerVersion: catalog.provider.providerVersion,
    },
    build: {
      mode: catalog.build.mode,
      sourceRoot: catalog.build.sourceRoot,
      sourceDigest: catalog.build.sourceDigest,
    },
    objects: catalog.objects.map((object) => ({
      id: object.id,
      kind: object.kind,
      readonly: object.readonly,
      source: {
        schemaName: object.source.schemaName,
        objectName: object.source.objectName,
        sourceFile: object.source.sourceFile ?? null,
        providerObjectId: object.source.providerObjectId ?? null,
      },
      graphql: {
        typeName: object.graphql.typeName,
        collectionField: object.graphql.collectionField,
        itemField: object.graphql.itemField ?? null,
      },
      identity: {
        mode: object.identity.mode,
        fields: [...object.identity.fields],
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
        sourceFields: [...relation.sourceFields],
        targetFields: [...relation.targetFields],
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
    })),
    diagnostics: diagnosticsToJson(catalog.diagnostics),
  };
}

function catalogLockToJson(catalog: GraphqlCatalog): Record<string, unknown> {
  return {
    catalogVersion: catalog.catalogVersion,
    sourceDigest: catalog.build.sourceDigest,
    providerVersion: catalog.provider.providerVersion,
  };
}

function diagnosticsToJson(diagnostics: readonly GraphqlCatalogDiagnostic[]): readonly Record<string, unknown>[] {
  return diagnostics.map((diagnostic) => ({
    severity: diagnostic.severity,
    code: diagnostic.code,
    message: diagnostic.message,
    objectId: diagnostic.objectId ?? null,
    field: diagnostic.field ?? null,
  }));
}

function catalogFromJson(json: Record<string, unknown>): GraphqlCatalog {
  const providerJson = requireObject(json.provider, 'catalog.json provider must be an object.');
  const buildJson = requireObject(json.build, 'catalog.json build must be an object.');
  const objectsJson = requireArray(json.objects, 'catalog.json objects must be an array.');
  const diagnosticsJson = Array.isArray(json.diagnostics) ? json.diagnostics : [];

  return {
    catalogVersion: requireString(json.catalogVersion, 'catalog.json catalogVersion must be a string.'),
    provider: {
      kind: requireString(providerJson.kind, 'catalog.json provider.kind must be a string.'),
      engine: requireString(providerJson.engine, 'catalog.json provider.engine must be a string.'),
      providerVersion: requireString(providerJson.providerVersion, 'catalog.json provider.providerVersion must be a string.'),
    },
    build: {
      mode: requireBuildMode(buildJson.mode),
      sourceRoot: requireString(buildJson.sourceRoot, 'catalog.json build.sourceRoot must be a string.'),
      sourceDigest: requireString(buildJson.sourceDigest, 'catalog.json build.sourceDigest must be a string.'),
    },
    objects: objectsJson.map((objectJson) => objectFromJson(requireObject(objectJson, 'catalog.json object must be an object.'))),
    diagnostics: diagnosticsJson.map((diagnosticJson) => diagnosticFromJson(requireObject(diagnosticJson, 'catalog.json diagnostic must be an object.'))),
  };
}

function catalogLockFromJson(json: Record<string, unknown>): {
  catalogVersion: string;
  sourceDigest: string;
  providerVersion: string;
} {
  return {
    catalogVersion: requireString(json.catalogVersion, 'catalog.lock catalogVersion must be a string.'),
    sourceDigest: requireString(json.sourceDigest, 'catalog.lock sourceDigest must be a string.'),
    providerVersion: requireString(json.providerVersion, 'catalog.lock providerVersion must be a string.'),
  };
}

function objectFromJson(json: Record<string, unknown>): GraphqlPublishedObject {
  const sourceJson = requireObject(json.source, 'catalog.json object.source must be an object.');
  const graphqlJson = requireObject(json.graphql, 'catalog.json object.graphql must be an object.');
  const identityJson = requireObject(json.identity, 'catalog.json object.identity must be an object.');
  const capabilitiesJson = requireObject(json.capabilities, 'catalog.json object.capabilities must be an object.');
  const paginationJson = requireObject(
    capabilitiesJson.pagination,
    'catalog.json object.capabilities.pagination must be an object.',
  );

  return {
    id: requireString(json.id, 'catalog.json object.id must be a string.'),
    kind: requirePhysicalObjectKind(json.kind),
    readonly: requireBoolean(json.readonly, 'catalog.json object.readonly must be a boolean.'),
    source: {
      schemaName: requireString(sourceJson.schemaName, 'catalog.json object.source.schemaName must be a string.'),
      objectName: requireString(sourceJson.objectName, 'catalog.json object.source.objectName must be a string.'),
      sourceFile: nullableString(sourceJson.sourceFile),
      providerObjectId: nullableString(sourceJson.providerObjectId),
    },
    graphql: {
      typeName: requireString(graphqlJson.typeName, 'catalog.json object.graphql.typeName must be a string.'),
      collectionField: requireString(
        graphqlJson.collectionField,
        'catalog.json object.graphql.collectionField must be a string.',
      ),
      itemField: nullableString(graphqlJson.itemField),
    },
    identity: {
      mode: requireIdentityMode(identityJson.mode),
      fields: requireStringArray(identityJson.fields, 'catalog.json object.identity.fields must be a string array.'),
      origin: requireOrigin(identityJson.origin),
    },
    fields: requireArray(json.fields, 'catalog.json object.fields must be an array.').map((fieldJson) => {
      const field = requireObject(fieldJson, 'catalog.json field must be an object.');
      return {
        column: requireString(field.column, 'catalog.json field.column must be a string.'),
        publicName: requireString(field.publicName, 'catalog.json field.publicName must be a string.'),
        type: requireString(field.type, 'catalog.json field.type must be a string.'),
        nullable: requireBoolean(field.nullable, 'catalog.json field.nullable must be a boolean.'),
        visibility: requireFieldVisibility(field.visibility),
        filterable: requireBoolean(field.filterable, 'catalog.json field.filterable must be a boolean.'),
        sortable: requireBoolean(field.sortable, 'catalog.json field.sortable must be a boolean.'),
        sensitive: requireBoolean(field.sensitive, 'catalog.json field.sensitive must be a boolean.'),
        origin: requireOrigin(field.origin),
      };
    }),
    relations: requireArray(json.relations, 'catalog.json object.relations must be an array.').map((relationJson) => {
      const relation = requireObject(relationJson, 'catalog.json relation must be an object.');
      return {
        name: requireString(relation.name, 'catalog.json relation.name must be a string.'),
        target: requireString(relation.target, 'catalog.json relation.target must be a string.'),
        cardinality: requireRelationCardinality(relation.cardinality),
        sourceFields: requireStringArray(relation.sourceFields, 'catalog.json relation.sourceFields must be a string array.'),
        targetFields: requireStringArray(relation.targetFields, 'catalog.json relation.targetFields must be a string array.'),
        origin: requireOrigin(relation.origin),
      };
    }),
    capabilities: {
      item: requireBoolean(capabilitiesJson.item, 'catalog.json capabilities.item must be a boolean.'),
      collection: requireBoolean(capabilitiesJson.collection, 'catalog.json capabilities.collection must be a boolean.'),
      filter: requireBoolean(capabilitiesJson.filter, 'catalog.json capabilities.filter must be a boolean.'),
      sort: requireBoolean(capabilitiesJson.sort, 'catalog.json capabilities.sort must be a boolean.'),
      pagination: {
        mode: requirePaginationMode(paginationJson.mode),
        defaultLimit: requireNumber(paginationJson.defaultLimit, 'catalog.json pagination.defaultLimit must be a number.'),
        maxLimit: requireNumber(paginationJson.maxLimit, 'catalog.json pagination.maxLimit must be a number.'),
      },
    },
  };
}

function diagnosticFromJson(json: Record<string, unknown>): GraphqlCatalogDiagnostic {
  return {
    severity: requireDiagnosticSeverity(json.severity),
    code: requireString(json.code, 'catalog.json diagnostic.code must be a string.'),
    message: requireString(json.message, 'catalog.json diagnostic.message must be a string.'),
    objectId: nullableString(json.objectId),
    field: nullableString(json.field),
  };
}

function parseJsonObject(text: string, errorMessage: string): Record<string, unknown> {
  let decoded: unknown;
  try {
    decoded = JSON.parse(text) as unknown;
  } catch (error) {
    throw new GraphqlArtifactLoadError(String(error instanceof Error ? error.message : error));
  }
  if (!decoded || typeof decoded !== 'object' || Array.isArray(decoded)) {
    throw new GraphqlArtifactLoadError(errorMessage);
  }
  return decoded as Record<string, unknown>;
}

function requireObject(value: unknown, errorMessage: string): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new GraphqlArtifactLoadError(errorMessage);
  }
  return value as Record<string, unknown>;
}

function requireArray(value: unknown, errorMessage: string): readonly unknown[] {
  if (!Array.isArray(value)) {
    throw new GraphqlArtifactLoadError(errorMessage);
  }
  return value;
}

function requireString(value: unknown, errorMessage: string): string {
  if (typeof value !== 'string') {
    throw new GraphqlArtifactLoadError(errorMessage);
  }
  return value;
}

function nullableString(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

function requireBoolean(value: unknown, errorMessage: string): boolean {
  if (typeof value !== 'boolean') {
    throw new GraphqlArtifactLoadError(errorMessage);
  }
  return value;
}

function requireNumber(value: unknown, errorMessage: string): number {
  if (typeof value !== 'number') {
    throw new GraphqlArtifactLoadError(errorMessage);
  }
  return value;
}

function requireStringArray(value: unknown, errorMessage: string): readonly string[] {
  const array = requireArray(value, errorMessage);
  return array.map((item) => requireString(item, errorMessage));
}

function requireBuildMode(value: unknown): GraphqlCatalogBuildMode {
  switch (value) {
    case GraphqlCatalogBuildMode.Compile:
    case GraphqlCatalogBuildMode.Runtime:
      return value;
    default:
      throw new GraphqlArtifactLoadError(`Unknown build mode ${String(value)}.`);
  }
}

function requirePhysicalObjectKind(value: unknown): PhysicalObjectKind {
  switch (value) {
    case PhysicalObjectKind.Table:
    case PhysicalObjectKind.View:
      return value;
    default:
      throw new GraphqlArtifactLoadError(`Unknown object kind ${String(value)}.`);
  }
}

function requireIdentityMode(value: unknown): GraphqlCatalogIdentityMode {
  switch (value) {
    case GraphqlCatalogIdentityMode.Single:
    case GraphqlCatalogIdentityMode.Composite:
    case GraphqlCatalogIdentityMode.None:
      return value;
    default:
      throw new GraphqlArtifactLoadError(`Unknown identity mode ${String(value)}.`);
  }
}

function requireOrigin(value: unknown): GraphqlCatalogOrigin {
  switch (value) {
    case GraphqlCatalogOrigin.Inferred:
    case GraphqlCatalogOrigin.Annotated:
      return value;
    default:
      throw new GraphqlArtifactLoadError(`Unknown origin ${String(value)}.`);
  }
}

function requireFieldVisibility(value: unknown): GraphqlCatalogFieldVisibility {
  switch (value) {
    case GraphqlCatalogFieldVisibility.Public:
    case GraphqlCatalogFieldVisibility.Hidden:
      return value;
    default:
      throw new GraphqlArtifactLoadError(`Unknown field visibility ${String(value)}.`);
  }
}

function requireRelationCardinality(value: unknown): GraphqlCatalogRelationCardinality {
  switch (value) {
    case GraphqlCatalogRelationCardinality.One:
    case GraphqlCatalogRelationCardinality.Many:
      return value;
    default:
      throw new GraphqlArtifactLoadError(`Unknown relation cardinality ${String(value)}.`);
  }
}

function requirePaginationMode(value: unknown): GraphqlCatalogPaginationMode {
  switch (value) {
    case GraphqlCatalogPaginationMode.Offset:
    case GraphqlCatalogPaginationMode.None:
      return value;
    default:
      throw new GraphqlArtifactLoadError(`Unknown pagination mode ${String(value)}.`);
  }
}

function requireDiagnosticSeverity(value: unknown): GraphqlCatalogDiagnosticSeverity {
  switch (value) {
    case GraphqlCatalogDiagnosticSeverity.Error:
    case GraphqlCatalogDiagnosticSeverity.Warning:
    case GraphqlCatalogDiagnosticSeverity.Info:
      return value;
    default:
      throw new GraphqlArtifactLoadError(`Unknown diagnostic severity ${String(value)}.`);
  }
}

function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map((entry) => canonicalize(entry));
  }
  if (value && typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>).sort(([left], [right]) => left.localeCompare(right));
    return Object.fromEntries(entries.map(([key, entryValue]) => [key, canonicalize(entryValue)]));
  }
  return value;
}

export type GraphqlSourceDigestResolver = GraphqlSourceDigestFactory;