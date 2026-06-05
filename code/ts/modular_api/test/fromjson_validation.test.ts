/**
 * RED — fromJson must validate required fields and types, returning 400.
 *
 * fromJson validates structure (field presence + JSON type correctness).
 * validate() handles only business rules.
 *
 * Error message contract (identical across all 3 SDKs for parity):
 *   - Missing required field: "Missing required field: {name}"
 *   - Wrong JSON type:        "Field '{name}' must be of type {type}"
 */

import { describe, it, expect } from 'vitest';
import { Input, Field, InputValidationError } from '../src/index';

// ── Stubs ────────────────────────────────────────────────────────────────

class StrictInput extends Input {
  @Field.string({ description: 'Name' })
  name!: string;

  @Field.integer({ description: 'Age' })
  age!: number;

  static fromJson(json: Record<string, unknown>): StrictInput {
    Input.validateJson(json, StrictInput);
    const instance = new StrictInput();
    instance.name = json['name'] as string;
    instance.age = json['age'] as number;
    return instance;
  }
}

// ── Unit: validateJson rejects missing fields and wrong types ────────────

describe('Input.validateJson', () => {
  it('throws InputValidationError for missing required field', () => {
    expect(() => Input.validateJson({}, StrictInput)).toThrow(
      InputValidationError,
    );
    expect(() => Input.validateJson({}, StrictInput)).toThrow(
      'Missing required field: name',
    );
  });

  it('throws InputValidationError for wrong type (int where string expected)', () => {
    expect(
      () => Input.validateJson({ name: 123, age: 25 }, StrictInput),
    ).toThrow(InputValidationError);
    expect(
      () => Input.validateJson({ name: 123, age: 25 }, StrictInput),
    ).toThrow("Field 'name' must be of type string");
  });

  it('throws InputValidationError for wrong type (string where integer expected)', () => {
    expect(
      () => Input.validateJson({ name: 'Alice', age: 'twenty-five' }, StrictInput),
    ).toThrow(InputValidationError);
    expect(
      () => Input.validateJson({ name: 'Alice', age: 'twenty-five' }, StrictInput),
    ).toThrow("Field 'age' must be of type integer");
  });

  it('does not throw for valid JSON', () => {
    expect(
      () => Input.validateJson({ name: 'Alice', age: 25 }, StrictInput),
    ).not.toThrow();
  });

  it('fromJson returns valid instance', () => {
    const input = StrictInput.fromJson({ name: 'Alice', age: 25 });
    expect(input.name).toBe('Alice');
    expect(input.age).toBe(25);
  });
});

// ── Stub with object field ───────────────────────────────────────────────

class ObjectInput extends Input {
  @Field.string({ description: 'ID' })
  id!: string;

  @Field.object({ description: 'Nested object' })
  details!: Record<string, unknown>;

  static fromJson(json: Record<string, unknown>): ObjectInput {
    Input.validateJson(json, ObjectInput);
    const instance = new ObjectInput();
    instance.id = json['id'] as string;
    instance.details = json['details'] as Record<string, unknown>;
    return instance;
  }
}

// ── Unit: validateJson handles object type ───────────────────────────────

describe('Input.validateJson — object type', () => {
  it('accepts plain object for Field.object', () => {
    expect(
      () => Input.validateJson({ id: 'abc', details: { amount: 100 } }, ObjectInput),
    ).not.toThrow();
  });

  it('rejects string for Field.object', () => {
    expect(
      () => Input.validateJson({ id: 'abc', details: 'not-an-object' }, ObjectInput),
    ).toThrow("Field 'details' must be of type object");
  });

  it('rejects array for Field.object', () => {
    expect(
      () => Input.validateJson({ id: 'abc', details: [1, 2] }, ObjectInput),
    ).toThrow("Field 'details' must be of type object");
  });
});
