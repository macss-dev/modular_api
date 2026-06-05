import { describe, it, expect, vi } from 'vitest';
import { Input, Output } from '../../src/core/usecase';
import { Field } from '../../src/core/schema/field';

describe('Manual toSchema() deprecation warning', () => {
  it('warns when Input subclass overrides toSchema() manually', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

    class LegacyInput extends Input {
      name!: string;

      toJson() {
        return { name: this.name };
      }

      toSchema() {
        return { type: 'object' };
      }
    }

    const input = new LegacyInput();
    const schema = input.toSchema();

    // The override still works
    expect(schema).toEqual({ type: 'object' });

    // But a deprecation warning was emitted
    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining('toSchema() is deprecated'),
    );

    warnSpy.mockRestore();
  });

  it('warns when Output subclass overrides toSchema() manually', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

    class LegacyOutput extends Output {
      message!: string;

      get statusCode() {
        return 200;
      }

      toJson() {
        return { message: this.message };
      }

      toSchema() {
        return { type: 'object' };
      }
    }

    const output = new LegacyOutput();
    const schema = output.toSchema();

    expect(schema).toEqual({ type: 'object' });
    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining('toSchema() is deprecated'),
    );

    warnSpy.mockRestore();
  });

  it('does NOT warn when using @Field decorators (no manual override)', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

    class ModernInput extends Input {
      @Field.string({ description: 'name' })
      name!: string;
    }

    const input = new ModernInput();
    input.toSchema();

    expect(warnSpy).not.toHaveBeenCalled();

    warnSpy.mockRestore();
  });

  it('warns only once per class (not on every call)', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

    class RepeatedInput extends Input {
      toJson() {
        return {};
      }

      toSchema() {
        return { type: 'object' };
      }
    }

    const a = new RepeatedInput();
    a.toSchema();
    a.toSchema();
    new RepeatedInput().toSchema();

    // Only warned once for the class, not per call
    expect(warnSpy).toHaveBeenCalledTimes(1);

    warnSpy.mockRestore();
  });
});
