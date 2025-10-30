/// Public library for modular_api package.
/// This library provides a use case centric API toolkit for Dart applications,
/// including Shelf UseCase base class, HTTP adapters, CORS/API-Key middlewares,
/// and OpenAPI specifications.

library;

// Core
export 'src/core/modular_api.dart' show ModularApi, ModuleBuilder;
export 'src/core/usecase/usecase.dart' show UseCase, Input, Output;
export 'src/core/usecase/usecase_test_handler.dart' show useCaseTestHandler;

// Middlewares
export 'src/middlewares/cors.dart' show exampleCorsMiddleware;
export 'src/middlewares/apikey.dart' show exampleApiKeyMiddleware;

// Clients
export 'src/clients/http/http_client.dart' show httpClient;
export 'src/clients/db/db_client.dart' show DbClient;

// OpenAPI
export 'src/openapi/openapi.dart' show OpenApi;

// utils
export 'src/utils/env.dart' show Env;
export 'src/utils/get_local_ip.dart' show getLocalIp;
