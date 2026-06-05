import { describe, it, expect } from 'vitest';
import { Input, Output } from '../../src/core/usecase';
import { Field } from '../../src/core/schema/field';

// ── Test DTOs with @Field decorators ─────────────────────────

class NameInput extends Input {
  @Field.string({ description: 'Name to greet' })
  name!: string;

  static fromJson(json: Record<string, unknown>): NameInput {
    const instance = new NameInput();
    instance.name = (json['name'] ?? '').toString();
    return instance;
  }
}

class GreetOutput extends Output {
  @Field.string({ description: 'Greeting message' })
  message!: string;

  get statusCode() {
    return 200;
  }

  static fromJson(json: Record<string, unknown>): GreetOutput {
    const instance = new GreetOutput();
    instance.message = (json['message'] ?? '').toString();
    return instance;
  }
}

class OptionalInput extends Input {
  @Field.string({ description: 'Required name' })
  name!: string;

  @Field.optional(Field.string({ description: 'Optional nickname' }))
  nickname?: string;

  static fromJson(json: Record<string, unknown>): OptionalInput {
    const instance = new OptionalInput();
    instance.name = (json['name'] ?? '').toString();
    if (json['nickname'] != null) {
      instance.nickname = json['nickname'].toString();
    }
    return instance;
  }
}

// ── Input auto-schema tests ──────────────────────────────────

describe('Input auto-schema from @Field decorators', () => {
  it('toSchema() returns correct OpenAPI schema', () => {
    const schema = new NameInput().toSchema();
    expect(schema).toEqual({
      type: 'object',
      properties: {
        name: { type: 'string', description: 'Name to greet' },
      },
      required: ['name'],
    });
  });

  it('toJson() serializes decorated fields', () => {
    const input = NameInput.fromJson({ name: 'Carlos' });
    expect(input.toJson()).toEqual({ name: 'Carlos' });
  });

  it('fromJson() populates fields', () => {
    const input = NameInput.fromJson({ name: 'Maria' });
    expect(input.name).toBe('Maria');
  });

  it('optional field excluded from required and marked nullable', () => {
    const schema = new OptionalInput().toSchema();
    expect(schema).toEqual({
      type: 'object',
      properties: {
        name: { type: 'string', description: 'Required name' },
        nickname: { type: 'string', description: 'Optional nickname', nullable: true },
      },
      required: ['name'],
    });
  });
});

// ── Output auto-schema tests ─────────────────────────────────

describe('Output auto-schema from @Field decorators', () => {
  it('toSchema() returns correct OpenAPI schema', () => {
    const schema = new GreetOutput().toSchema();
    expect(schema).toEqual({
      type: 'object',
      properties: {
        message: { type: 'string', description: 'Greeting message' },
      },
      required: ['message'],
    });
  });

  it('toJson() serializes decorated fields', () => {
    const output = GreetOutput.fromJson({ message: 'Hello!' });
    expect(output.toJson()).toEqual({ message: 'Hello!' });
  });

  it('statusCode is still abstract and implemented by subclass', () => {
    const output = new GreetOutput();
    expect(output.statusCode).toBe(200);
  });
});
