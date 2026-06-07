// ============================================================
// core/usecase_handler.ts
// Express RequestHandler adapter for any UseCase.
// Mirror of useCaseHttpHandler() in Dart (Shelf).
// ============================================================

import type { Request, Response, RequestHandler } from 'express';
import type { UseCaseFactory, Output } from './usecase';
import { Input } from './usecase';
import { UseCaseException } from './use_case_exception';
import { InputValidationError } from './input_validation_error';
import { LOGGER_LOCALS_KEY } from './logger/logging_middleware';
import type { ModularLogger } from './logger/logger';

const JSON_HEADERS = { 'Content-Type': 'application/json; charset=utf-8' };

export interface UseCaseHandlerOptions {
  /** Input class for pre-validation before fromJson (enables strict factories). */
  inputClass?: abstract new (...args: unknown[]) => Input;
}

/**
 * Wraps any UseCase factory into an Express RequestHandler.
 *
 * Lifecycle (mirrors Dart useCaseHttpHandler):
 *   1. Parse body (POST/PUT/PATCH) or query params (GET/DELETE)
 *   2. Pre-validate against @Field metadata (when inputClass provided)
 *   3. Build UseCase via factory(json)
 *   4. Post-validate (legacy fallback when no inputClass)
 *   5. Call validate() — return 400 if error string returned
 *   6. Call execute()
 *   7. Return output.toJson() with output.statusCode
 *
 * Errors:
 *   - InputValidationError → 400 with structured error message
 *   - UseCaseException     → statusCode from exception, structured JSON body
 *   - Any other Error      → 500 Internal Server Error
 *
 * Usage:
 * ```ts
 * router.post('/hello', useCaseHandler(SayHello.fromJson, { inputClass: HelloInput }));
 * ```
 */
export function useCaseHandler<I extends Input, O extends Output>(
  factory: UseCaseFactory<I, O>,
  options: UseCaseHandlerOptions = {},
): RequestHandler {
  return async (req: Request, res: Response): Promise<void> => {
    try {
      // 1. Extract payload
      const data: Record<string, unknown> =
        req.method.toUpperCase() === 'GET' || req.method.toUpperCase() === 'DELETE'
          ? { ...req.query, ...req.params }
          : ((req.body as Record<string, unknown>) ?? {});

      // 2. Pre-validate BEFORE fromJson (when inputClass provided)
      if (options.inputClass) {
        Input.validateJson(data, options.inputClass);
      }

      // 3. Build use case
      const useCase = factory(data);

      // 3a. Post-validate for legacy path (no inputClass)
      if (!options.inputClass) {
        Input.validateJson(
          data,
          useCase.input.constructor as abstract new (...args: unknown[]) => unknown,
        );
      }

      // 2b. Inject request-scoped logger (if logging middleware is active)
      const logger = res.locals[LOGGER_LOCALS_KEY] as ModularLogger | undefined;
      if (logger) {
        useCase.logger = logger;
      }

      // 3. Validate
      const validationError = useCase.validate();
      if (validationError !== null) {
        res.status(400).set(JSON_HEADERS).json({ error: validationError });
        return;
      }

      // 4. Execute
      const output = await useCase.execute();

      // 5. Respond
      res.status(output.statusCode).set(JSON_HEADERS).json(output.toJson());
    } catch (err) {
      const logger = res.locals[LOGGER_LOCALS_KEY] as ModularLogger | undefined;

      if (err instanceof InputValidationError) {
        res.status(400).set(JSON_HEADERS).json({ error: err.message });
        return;
      }
      if (err instanceof UseCaseException) {
        logger?.error('UseCaseException', { error: err.toString(), status: err.statusCode });
        res.status(err.statusCode).set(JSON_HEADERS).json(err.toJson());
        return;
      }
      logger?.error('Unexpected error in use case handler', { error: String(err) });
      res.status(500).set(JSON_HEADERS).json({ error: 'Internal server error' });
    }
  };
}
