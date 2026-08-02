import { describe, expect, it } from 'vitest';

import { Field, Input, Output } from '../../src';
import { getFieldMetadata } from '../../src/core/schema/field';
import { useCaseHandler } from '../../src/core/usecase_handler';

/**
 * The public API accepts a consumer's own `Input` / `Output` subclasses.
 *
 * **This is a type-level regression test, and the assertions that matter are the ones the compiler
 * makes.** `inputClass` was typed `abstract new (...args: unknown[]) => Input`, which looks like "any
 * class producing an Input" and is not: parameter contravariance requires the class's own constructor
 * parameters to accept `unknown`, and no real class does. A consumer writing the obvious thing —
 *
 *     class DniInput extends Input {
 *       constructor(public readonly dni: string) { super(); }
 *     }
 *
 * — could not pass `DniInput` as `inputClass` without a cast. The framework's own tests never caught
 * it because they only ever declared parameterless constructors, and because `vitest` does not
 * typecheck: `tsc --noEmit` over the test directory was the only thing that could see it, and it was
 * not being run.
 *
 * The fix is `never[]`, the standard idiom: `never` is assignable to every parameter type, so any
 * constructor fits. Nothing is lost, because the framework never *constructs* through this type — it
 * only reads decorator metadata off the constructor, which `getFieldMetadata` does below.
 *
 * If someone changes `never[]` back to `unknown[]`, this file stops compiling.
 */

// A constructor with a required, typed parameter — the shape that used to be rejected.
class DniInput extends Input {
  @Field.string({ description: 'Document number', example: '12345678' })
  dni!: string;

  constructor(dni: string) {
    super();
    this.dni = dni;
  }
}

// Two parameters, one optional, to cover the arity the old signature also rejected.
class DetalleOutput extends Output {
  @Field.string({ description: 'Echo of the input', example: '12345678' })
  echo!: string;

  constructor(echo: string, private readonly note?: string) {
    super();
    this.echo = echo;
  }

  get statusCode(): number {
    return 200;
  }

  describe(): string {
    return this.note ?? this.echo;
  }
}

class ParameterlessInput extends Input {
  @Field.string({ description: 'Anything', example: 'ping' })
  value = 'ping';
}

describe('a consumer class with a typed constructor', () => {
  it('is accepted as inputClass', () => {
    // The compiler is the assertion. This line failed to typecheck while `inputClass` was
    // `abstract new (...args: unknown[]) => Input`.
    const handler = useCaseHandler(
      (json) => ({ input: new DniInput(String(json['dni'])) }) as never,
      { inputClass: DniInput },
    );

    expect(typeof handler).toBe('function');
  });

  it('a parameterless class is still accepted', () => {
    // The old signature accepted these, which is exactly why the defect stayed hidden — every test
    // in the repo declared its inputs this way.
    const handler = useCaseHandler(() => ({}) as never, { inputClass: ParameterlessInput });

    expect(typeof handler).toBe('function');
  });

  it('field metadata is still readable, which is all the framework uses the type for', () => {
    // The reason `never[]` costs nothing: the type is reflection-only. The framework reads decorator
    // metadata off the constructor and never invokes it, so a signature that cannot be *called* is
    // not a limitation.
    expect(getFieldMetadata(DniInput).map((field) => field.name)).toContain('dni');
    expect(getFieldMetadata(DetalleOutput).map((field) => field.name)).toContain('echo');
  });

  it('the class remains ordinarily constructible by the consumer', () => {
    // The type governs what the framework accepts, not what the consumer can do with their own class.
    const output = new DetalleOutput('12345678', 'a note');

    expect(output.statusCode).toBe(200);
    expect(output.describe()).toBe('a note');
    expect(new DniInput('12345678').dni).toBe('12345678');
  });
});
