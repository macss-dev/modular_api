/// Public library for modular_api package.
/// Use-case centric API toolkit for Dart — Shelf + OpenAPI, nothing more.

library;

export 'src/version.dart' show modularApiPackageVersion;

// Shelf types
export 'package:shelf/shelf.dart' show Middleware, Handler, Request, Response;

// Core
export 'src/core/modular_api.dart' show ModularApi, ModuleBuilder;
export 'src/core/plugin.dart'
    show
        Capability,
        CapabilityHandle,
        HostMetadata,
        ModuleExtensionContribution,
        ModuleExtensionPoint,
        Plugin,
        PluginHost,
        PluginHostError,
        PluginManifest,
        PluginMiddleware,
        PluginRequestContext,
        PluginRequirement,
        PluginRoute,
        PluginValidationResult,
        RegisteredModuleView,
        RegisteredUseCaseView,
        RuntimePluginHost,
        orderPlugins,
        ShutdownAwarePlugin,
        ValidatingPlugin,
        hostApiVersion;
export 'src/core/usecase/usecase.dart' show UseCase, Input, Output;
export 'src/core/usecase/use_case_exception.dart' show UseCaseException;
export 'src/core/schema/field.dart'
    show SchemaField, buildSchema, InputValidationException, validateJsonFields;
// Logger
export 'src/core/logger/logger.dart' show LogLevel, ModularLogger;

// Health
export 'src/core/health/health_check.dart'
    show HealthCheck, HealthCheckResult, HealthStatus;
export 'src/core/health/health_service.dart' show HealthService, HealthResponse;
export 'src/core/health/health_handler.dart' show healthHandler;

// GraphQL
export 'src/graphql/catalog/graphql_catalog_builder.dart'
    show
        GraphqlCatalog,
        GraphqlCatalogBuild,
        GraphqlCatalogBuildMode,
        GraphqlCatalogBuilder,
        GraphqlCatalogCapabilities,
        GraphqlCatalogDiagnostic,
        GraphqlCatalogDiagnosticSeverity,
        GraphqlCatalogField,
        GraphqlCatalogFieldVisibility,
        GraphqlCatalogGraphqlNames,
        GraphqlCatalogIdentity,
        GraphqlCatalogIdentityMode,
        GraphqlCatalogNaming,
        GraphqlCatalogOrigin,
        GraphqlCatalogPagination,
        GraphqlCatalogPaginationMode,
        GraphqlCatalogProvider,
        GraphqlCatalogRelation,
        GraphqlCatalogRelationCardinality,
        GraphqlCatalogSource,
        GraphqlPublishedObject;
export 'src/graphql/metadata/graphql_metadata_parser.dart'
    show
        GraphqlFieldMetadata,
        GraphqlMetadataDiagnostic,
        GraphqlMetadataFile,
        GraphqlMetadataLimit,
        GraphqlMetadataParseResult,
        GraphqlMetadataParser,
        GraphqlMetadataSeverity,
        GraphqlObjectMetadata,
        GraphqlRelationMetadata;
export 'src/graphql/read/sql_read_contract.dart'
    show
        ReadExecutionContext,
        RowSet,
        SqlParameter,
        SqlReadCommand,
        SqlReadCommandPurpose,
        SqlReadExecutor;
export 'src/graphql/runtime/graphql_runtime_options.dart'
    show
        GraphqlCatalogFactory,
        GraphqlEventSink,
        GraphqlOptions,
        GraphqlRequestEvent,
        GraphqlRequestPhase,
        GraphqlSourceDigestFactory,
        GraphqlSdlFactory;
export 'src/graphql/runtime/graphql_artifacts.dart'
    show
        GraphqlArtifactBundle,
        GraphqlArtifactCompileError,
        GraphqlArtifactCompiler;
export 'src/graphql/sqlserver/physical_model.dart'
    show
        PhysicalCatalog,
        PhysicalField,
        PhysicalObject,
        PhysicalObjectKind,
        PhysicalRelationSeed;

// Metrics
export 'src/core/metrics/metric.dart'
    show Counter, Gauge, Histogram, MetricSample;
export 'src/core/metrics/metric_registry.dart' show MetricsRegistrar;

// Middlewares
export 'src/middlewares/cors.dart' show corsMiddleware;

// OpenAPI
export 'src/openapi/openapi.dart' show OpenApi;
export 'src/openapi/swagger_docs.dart' show swaggerDocsHandler;
