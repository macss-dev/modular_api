# Changelog

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

