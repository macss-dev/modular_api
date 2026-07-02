// dto.ts — Web-safe DTO contract entry-point.
//
// Runtime-free surface for defining and validating request/response DTOs,
// without importing the server runtime. Import via '@macss/modular-api/dto'
// from packages shared with browser/front-end code, so the shared types never
// drag Node-only globals into a web bundle. (The barrel '@macss/modular-api'
// re-exports the full framework, including the Express server, and is
// server-only.)

export { Input, Output } from './core/usecase';
export { Field, getFieldMetadata } from './core/schema/field';
export type { FieldMeta, FieldOptions } from './core/schema/field';
export { UseCaseException } from './core/use_case_exception';
export { InputValidationError } from './core/input_validation_error';
