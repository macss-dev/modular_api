// ============================================================
// index.ts  — Public API barrel export
// This is the single entry point users import from:
//   import { ModularApi, UseCase, Input, Output } from 'modular_api'
// ============================================================

// Core abstractions
export { Input, Output, UseCase } from './core/usecase';
export type { UseCaseFactory } from './core/usecase';

// Schema decorators
export { Field, getFieldMetadata } from './core/schema/field';
export type { FieldMeta, FieldOptions } from './core/schema/field';

// Controlled error responses
export { UseCaseException } from './core/use_case_exception';
export { InputValidationError } from './core/input_validation_error';

// Main orchestrator
export { ModularApi } from './core/modular_api';
export type { ModularApiOptions } from './core/modular_api';
export { HOST_API_VERSION, PluginHostError } from './core/plugin';
export type {
  Capability,
  CapabilityHandle,
  HostMetadata,
  HttpMethod,
  MiddlewareSlot,
  ModuleExtensionContribution,
  ModuleExtensionPoint,
  Plugin,
  PluginHost,
  PluginManifest,
  PluginMiddleware,
  PluginRequestContext,
  PluginRequirement,
  PluginResponse,
  PluginRoute,
  PluginRouteVisibility,
  PluginValidationResult,
  RegisteredModuleView,
  RegisteredUseCaseView,
} from './core/plugin';

// Module builder (exposed for advanced / manual usage)
export { ModuleBuilder } from './core/module_builder';
export type { UseCaseOptions } from './core/module_builder';

// Middlewares
export { cors } from './middlewares/cors';
export type { CorsOptions } from './middlewares/cors';

// Health — IETF Health Check Response Format
export { HealthCheck, HealthCheckResult } from './core/health/health_check';
export type { HealthStatus } from './core/health/health_check';
export { HealthService, HealthResponse } from './core/health/health_service';
export type { HealthServiceOptions } from './core/health/health_service';
export { healthHandler } from './core/health/health_handler';

// Metrics — Prometheus /metrics endpoint (zero external dependencies)
export { Counter, Gauge, Histogram, DEFAULT_BUCKETS } from './core/metrics/metric';
export type { MetricSample } from './core/metrics/metric';
export { MetricRegistry, MetricsRegistrar } from './core/metrics/metric_registry';
export { metricsMiddleware, metricsHandler } from './core/metrics/metrics_middleware';
export type { MetricsMiddlewareOptions } from './core/metrics/metrics_middleware';

// Logger — Structured JSON logging (Loki/Grafana compatible)
export { LogLevel, RequestScopedLogger } from './core/logger/logger';
export type { ModularLogger } from './core/logger/logger';
export { loggingMiddleware, LOGGER_LOCALS_KEY } from './core/logger/logging_middleware';
export type { LoggingMiddlewareOptions } from './core/logger/logging_middleware';

// OpenAPI — Raw spec endpoints
export {
  buildOpenApiSpec,
  jsonToYaml,
  openApiJsonHandler,
  openApiYamlHandler,
} from './openapi/openapi';

// Swagger UI — inline HTML docs handler (PRD-003)
export { swaggerDocsHandler } from './openapi/swagger_docs';

// GraphQL SQL Server metadata surface
export { PhysicalObjectKind } from './graphql/sqlserver/physical_model';
export type {
  PhysicalCatalog,
  PhysicalField,
  PhysicalObject,
  PhysicalRelationSeed,
} from './graphql/sqlserver/physical_model';
export { SqlServerConnectionSettings } from './graphql/sqlserver/sql_server_connection_settings';
export { SqlServerMetadataReader } from './graphql/sqlserver/sql_server_metadata_reader';
export { GraphqlMetadataParser, GraphqlMetadataSeverity } from './graphql/metadata/graphql_metadata_parser';
export type {
  GraphqlFieldMetadata,
  GraphqlMetadataDiagnostic,
  GraphqlMetadataFile,
  GraphqlMetadataLimit,
  GraphqlMetadataParseResult,
  GraphqlObjectMetadata,
  GraphqlRelationMetadata,
} from './graphql/metadata/graphql_metadata_parser';
export {
  GraphqlCatalogBuildMode,
  GraphqlCatalogBuilder,
  GraphqlCatalogDiagnosticSeverity,
  GraphqlCatalogFieldVisibility,
  GraphqlCatalogIdentityMode,
  GraphqlCatalogNaming,
  GraphqlCatalogOrigin,
  GraphqlCatalogPaginationMode,
  GraphqlCatalogRelationCardinality,
} from './graphql/catalog/graphql_catalog_builder';
export type {
  GraphqlCatalog,
  GraphqlCatalogBuild,
  GraphqlCatalogCapabilities,
  GraphqlCatalogDiagnostic,
  GraphqlCatalogField,
  GraphqlCatalogGraphqlNames,
  GraphqlCatalogIdentity,
  GraphqlCatalogPagination,
  GraphqlCatalogProvider,
  GraphqlCatalogRelation,
  GraphqlCatalogSource,
  GraphqlPublishedObject,
} from './graphql/catalog/graphql_catalog_builder';
export { GraphqlSchemaSdlGenerator } from './graphql/schema/graphql_schema_sdl_generator';
export {
  ReadExecutionContext,
  RowSet,
  SqlCollectionSelection,
  SqlCountSelection,
  SqlFilterCondition,
  SqlFilterGroup,
  SqlFilterGroupKind,
  SqlFilterOperator,
  SqlItemSelection,
  SqlOrderByClause,
  SqlPage,
  SqlParameter,
  SqlReadCommand,
  SqlReadCommandPurpose,
  SqlRelationBatchSelection,
  SqlSortDirection,
} from './graphql/read/sql_read_contract';
export type { ReadExecutor } from './graphql/read/sql_read_contract';
export { SqlCatalogReadDispatcher, SqlServerReadCompiler } from './graphql/read/sqlserver_read_compiler';
