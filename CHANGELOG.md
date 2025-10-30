# Changelog

## [0.0.6] - 2025-10-30
### Added
- Exported `useCaseTestHandler` in main library export (`lib/modular_api.dart`) for convenient unit testing of UseCases without starting an HTTP server.
- Comprehensive documentation guides:
  - **AGENTS.md** — Framework overview and implementation guide optimized for AI assistants
  - **docs/USECASE_DTO_GUIDE.md** — Complete guide for creating Input/Output DTOs with type mapping reference and advanced examples
  - **docs/usecase_implementation.md** — Step-by-step guide for implementing UseCases with validation, database access, and repository patterns
  - **docs/TESTING_GUIDE.md** — Quick reference for testing UseCases using `useCaseTestHandler`
- Complete test suite for template project:
  - `template/test/module1/hello_world_test.dart` — 5 tests for HelloWorld use case
  - `template/test/module2/sum_case_test.dart` — 7 tests for SumCase use case
  - `template/test/module2/upper_case_test.dart` — 7 tests for UpperCase use case
  - `template/test/module3/lower_case_test.dart` — 7 tests for LowerCase use case
  - `template/test/module3/multiply_case_test.dart` — 9 tests for MultiplyCase use case
  - All 35 tests demonstrate proper usage of `useCaseTestHandler` with success and failure scenarios

## [0.0.5] - 2025-10-25
### Changed
- `Env` now initializes automatically on first access (lazy singleton pattern). No need to call `Env.init()` explicitly, though it remains available for manual initialization if needed.
- .usecase() now trims leading slashes from usecase names to prevent double slashes in registered paths.

## [0.0.4] - 2025-10-23
### Changed
- `Env` behavior: when a `.env` file is not found the library reads values from `Platform.environment`. If a requested key is missing from both sources an `EnvKeyNotFoundException` is thrown.

## [0.0.3] - 2025-10-23
### Added
- Automatic health endpoint: the server registers `GET /health` which responds with `ok` on startup. Implemented in `modular_api.dart` (exposes `_root.get('/health', (Request request) => Response.ok('ok'));`).


All notable changes to this project will be documented in this file.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## [0.0.2] - 2025-10-21
### Changed
- refactor: improve OpenAPI initialization (now initialized automatically internally)
- Rename middlewares as examples
- rename example project to template
- Add a simple example

## [0.0.1] - 2025-10-21
### Added
- Initial release of **modular_api**. Main features:
  - Use-case centric framework with `UseCase<I extends Input, O extends Output>` base classes and DTO helpers (`Input`/`Output`).
  - HTTP adapter `useCaseHttpHandler()` to expose UseCases as Shelf `Handler`s.
  - Built-in middlewares: `cors()` and `apiKey()` for CORS handling and header-based API key authentication.
  - OpenAPI/Swagger generation helpers (`OpenApi.init`, `OpenApi.docs`) that infer schemas from DTO `toSchema()`.
  - Utilities: `Env.getString`, `Env.getInt`, `Env.setString` (.env support via dotenv) and `getLocalIp`.
  - Minimal ODBC `DbClient` (DSN-based) exported for database access; example factories and usage provided in `example/` (tested with Oracle and SQL Server; see `NOTICE` for provenance).
  - Example project demonstrating modules and usecases under `example/` and unit-test helpers (`useCaseTestHandler`) under `test/`.
  - Public API exports in `lib/modular_api.dart` for easy consumption.

