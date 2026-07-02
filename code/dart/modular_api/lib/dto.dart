/// Web-safe DTO contract for modular_api.
///
/// Runtime-free surface for **defining and validating** the request/response
/// DTOs of a use case, without pulling in the HTTP server runtime. Import this
/// instead of the full `package:modular_api/modular_api.dart` barrel from
/// packages that are shared with web/desktop clients (e.g. a Flutter app's
/// `dto` package), so the shared types never drag `dart:io` into a web build.
library;

export 'src/core/usecase/usecase.dart' show Input, Output;
export 'src/core/usecase/use_case_exception.dart' show UseCaseException;
export 'src/core/schema/field.dart'
    show SchemaField, buildSchema, validateJsonFields, InputValidationException;
