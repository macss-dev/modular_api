// ============================================================
// core/use_case_exception.ts
// Structured exception for controlled HTTP error responses.
// Mirror of UseCaseException in Dart.
// ============================================================

/**
 * Throw this inside `execute()` to return a specific HTTP status code
 * and a structured JSON error body — instead of a generic 500.
 *
 * Dart equivalent:
 *   throw UseCaseException(statusCode: 404, message: 'Not found');
 *
 * TypeScript usage:
 * ```ts
 * throw new UseCaseException({
 *   statusCode: 404,
 *   message: 'User not found',
 *   errorCode: 'USER_NOT_FOUND',
 * });
 * ```
 *
 * HTTP response body:
 * ```json
 * { "error": "USER_NOT_FOUND", "message": "User not found" }
 * ```
 */
export class UseCaseException extends Error {
  readonly statusCode: number;
  readonly message: string;
  readonly errorCode?: string;
  readonly details?: Record<string, unknown>;

  constructor(params: {
    statusCode: number;
    message: string;
    errorCode?: string;
    details?: Record<string, unknown>;
  }) {
    super(params.message);
    this.name = 'UseCaseException';
    this.statusCode = params.statusCode;
    this.message = params.message;
    this.errorCode = params.errorCode;
    this.details = params.details;
  }

  /** Serializes to the JSON body sent in the HTTP error response. */
  toJson(): Record<string, unknown> {
    const body: Record<string, unknown> = {
      error: this.errorCode ?? 'error',
      message: this.message,
    };
    if (this.details !== undefined) {
      body['details'] = this.details;
    }
    return body;
  }

  override toString(): string {
    const code = this.errorCode ? ` [${this.errorCode}]` : '';
    return `UseCaseException(${this.statusCode}): ${this.message}${code}`;
  }
}
