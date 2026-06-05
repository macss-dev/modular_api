// ============================================================
// core/input_validation_error.ts
// Thrown by Input.validateJson when required fields are missing
// or have the wrong JSON type.
//
// Error message contract (identical across all 3 SDKs for parity):
//   - "Missing required field: {name}"
//   - "Field '{name}' must be of type {type}"
// ============================================================

/**
 * Signals that the raw JSON payload failed structural validation
 * (missing required field or wrong JSON type).
 *
 * The handler catches this and returns HTTP 400 with `{ error: message }`.
 * Business-rule validation belongs in `UseCase.validate()` instead.
 */
export class InputValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'InputValidationError';
  }
}
