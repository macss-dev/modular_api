// ============================================================
// core/usecase.ts
// Base classes: Input, Output, UseCase<I, O>
// Mirror of the Dart abstract classes in usecase.dart
// ============================================================

import type { ModularLogger } from './logger/logger';
import { getFieldMetadata, type FieldMeta } from './schema/field';
import { InputValidationError } from './input_validation_error';

/**
 * Build an OpenAPI 3.0.3 JSON Schema from `@Field` decorator metadata.
 * Shared by both Input and Output base classes.
 */
function buildSchemaFromMetadata(fields: FieldMeta[]): Record<string, unknown> {
  const properties: Record<string, Record<string, unknown>> = {};
  const required: string[] = [];

  const exampleValues: Record<string, unknown> = {};

  for (const field of fields) {
    const prop: Record<string, unknown> = { type: field.type };
    if (field.description) prop.description = field.description;
    if (field.nullable) prop.nullable = true;
    if (field.items) prop.items = field.items;
    if (field.example !== undefined) {
      prop.example = field.example;
      exampleValues[field.name] = field.example;
    }
    properties[field.name] = prop;

    if (field.required) {
      required.push(field.name);
    }
  }

  const schema: Record<string, unknown> = { type: 'object', properties };
  if (required.length > 0) {
    schema.required = required;
  }
  if (Object.keys(exampleValues).length > 0) {
    schema.example = exampleValues;
  }
  return schema;
}

/**
 * Serialize decorated fields from an instance to a plain object.
 * Shared by both Input and Output base classes.
 */
function serializeFromMetadata(instance: Record<string, unknown>, fields: FieldMeta[]): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  for (const field of fields) {
    const value = instance[field.name];
    if (value !== undefined) {
      result[field.name] = value;
    }
  }
  return result;
}

// Track classes that have already emitted a deprecation warning (once per class)
const _warnedInputClasses = new Set<Function>();
const _warnedOutputClasses = new Set<Function>();

/** Checks whether a JSON value matches the expected OpenAPI type. */
function isJsonTypeValid(value: unknown, expectedType: string): boolean {
  switch (expectedType) {
    case 'string':  return typeof value === 'string';
    case 'integer': return typeof value === 'number' && Number.isInteger(value);
    case 'number':  return typeof value === 'number';
    case 'boolean': return typeof value === 'boolean';
    case 'array':   return Array.isArray(value);
    case 'object':  return typeof value === 'object' && value !== null && !Array.isArray(value);
    default:        return true;
  }
}

/**
 * **Contract** — use `extends Input`.
 *
 * When subclass fields are decorated with `@Field`, `toJson()` and
 * `toSchema()` are provided automatically. Manual overrides still work
 * (deprecated — will be removed in v0.5.0).
 *
 * ```ts
 * class HelloInput extends Input {
 *   @Field.string({ description: 'Name to greet' })
 *   name!: string;
 *
 *   static fromJson(json: Record<string, unknown>) {
 *     const instance = new HelloInput();
 *     instance.name = (json['name'] ?? '').toString();
 *     return instance;
 *   }
 * }
 * ```
 */
export abstract class Input {
  constructor() {
    const cls = this.constructor;
    if (
      !_warnedInputClasses.has(cls) &&
      cls.prototype.toSchema !== Input.prototype.toSchema
    ) {
      _warnedInputClasses.add(cls);
      console.warn(
        `${cls.name}.toSchema() is deprecated. Remove it — schema is derived automatically from @Field decorators.`,
      );
    }
  }

  toJson(): Record<string, unknown> {
    const fields = getFieldMetadata(this.constructor as abstract new (...args: unknown[]) => unknown);
    if (fields.length > 0) {
      return serializeFromMetadata(this as unknown as Record<string, unknown>, fields);
    }
    // No decorator metadata — subclass must override (legacy path)
    throw new Error(`${this.constructor.name}.toJson() not implemented. Use @Field decorators or override toJson().`);
  }

  /**
   * Returns an OpenAPI-compatible JSON Schema describing this input.
   * Derived automatically from `@Field` decorators when present.
   */
  toSchema(): Record<string, unknown> {
    const fields = getFieldMetadata(this.constructor as abstract new (...args: unknown[]) => unknown);
    if (fields.length > 0) {
      return buildSchemaFromMetadata(fields);
    }
    // No decorator metadata — subclass must override (legacy path)
    throw new Error(`${this.constructor.name}.toSchema() not implemented. Use @Field decorators or override toSchema().`);
  }

  /**
   * Validates raw JSON against `@Field` metadata of `targetClass`.
   *
   * Throws {@link InputValidationError} when a required field is missing
   * or has the wrong JSON type. The handler catches this and returns 400.
   *
   * Error messages follow the cross-SDK parity contract:
   *   - `"Missing required field: {name}"`
   *   - `"Field '{name}' must be of type {type}"`
   */
  static validateJson(
    json: Record<string, unknown>,
    targetClass: abstract new (...args: unknown[]) => unknown,
  ): void {
    const fields = getFieldMetadata(targetClass);
    for (const field of fields) {
      if (!field.required) continue;

      if (!(field.name in json) || json[field.name] === undefined || json[field.name] === null) {
        throw new InputValidationError(`Missing required field: ${field.name}`);
      }

      if (!isJsonTypeValid(json[field.name], field.type)) {
        throw new InputValidationError(`Field '${field.name}' must be of type ${field.type}`);
      }
    }
  }
}

/**
 * **Contract** — use `extends Output`.
 *
 * When subclass fields are decorated with `@Field`, `toJson()` and
 * `toSchema()` are provided automatically. The implementor must define
 * `statusCode` explicitly — this forces developers to think about
 * HTTP status codes for every response.
 *
 * ```ts
 * class HelloOutput extends Output {
 *   @Field.string({ description: 'Greeting message' })
 *   message!: string;
 *
 *   get statusCode() { return 200; }
 * }
 * ```
 */
export abstract class Output {
  constructor() {
    const cls = this.constructor;
    if (
      !_warnedOutputClasses.has(cls) &&
      cls.prototype.toSchema !== Output.prototype.toSchema
    ) {
      _warnedOutputClasses.add(cls);
      console.warn(
        `${cls.name}.toSchema() is deprecated. Remove it — schema is derived automatically from @Field decorators.`,
      );
    }
  }

  toJson(): Record<string, unknown> {
    const fields = getFieldMetadata(this.constructor as abstract new (...args: unknown[]) => unknown);
    if (fields.length > 0) {
      return serializeFromMetadata(this as unknown as Record<string, unknown>, fields);
    }
    throw new Error(`${this.constructor.name}.toJson() not implemented. Use @Field decorators or override toJson().`);
  }

  toSchema(): Record<string, unknown> {
    const fields = getFieldMetadata(this.constructor as abstract new (...args: unknown[]) => unknown);
    if (fields.length > 0) {
      return buildSchemaFromMetadata(fields);
    }
    throw new Error(`${this.constructor.name}.toSchema() not implemented. Use @Field decorators or override toSchema().`);
  }

  /**
   * HTTP status code for the response.
   * Must be implemented explicitly (e.g. 200, 201, 400, 404).
   */
  abstract get statusCode(): number;
}

/**
 * Factory function type — the signature every UseCase class must expose
 * as a static method `fromJson`.
 *
 * Dart equivalent:
 *   static MyUseCase fromJson(Map<String, dynamic> json) { ... }
 */
export type UseCaseFactory<I extends Input = Input, O extends Output = Output> = (
  json: Record<string, unknown>,
) => UseCase<I, O>;

/**
 * **Contract** — use `implements UseCase<I, O>`.
 *
 * Pure interface: all members must be provided by the implementor.
 * This mirrors the Dart version where UseCase is 100% abstract.
 *
 * Lifecycle (handled by the framework):
 *   1. `fromJson(json)`    — static factory, builds the use case
 *   2. `validate()`        — return error string or null
 *   3. `execute()`         — run business logic, set `this.output`
 *   4. `output.toJson()`   — serialize and return to HTTP client
 *
 * ```ts
 * class SayHello implements UseCase<HelloInput, HelloOutput> {
 *   input: HelloInput;
 *   output!: HelloOutput;
 *
 *   constructor(input: HelloInput) { this.input = input; }
 *
 *   static fromJson(json: Record<string, unknown>) {
 *     return new SayHello(HelloInput.fromJson(json));
 *   }
 *
 *   validate(): string | null {
 *     if (!this.input.name) return 'name is required';
 *     return null;
 *   }
 *
 *   async execute(): Promise<void> {
 *     this.output = new HelloOutput(`Hello, ${this.input.name}!`);
 *   }
 *
 *   toJson() { return this.output.toJson(); }
 * }
 * ```
 */
export abstract class UseCase<I extends Input, O extends Output> {
  /** Input DTO — set in constructor. */
  abstract readonly input: I;

  /**
   * Request-scoped logger injected by the framework's logging middleware.
   * Available inside `execute()`. Undefined when running without middleware
   * or in tests that don't provide one.
   */
  logger?: ModularLogger;

  /**
   * Synchronous validation.
   * Return a human-readable error string to abort execution with HTTP 400.
   * Return null to proceed.
   */
  abstract validate(): string | null;

  /**
   * Business logic. Returns the Output DTO.
   * Keep this method free of HTTP concerns.
   */
  abstract execute(): Promise<O>;
}
