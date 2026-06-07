import { describe, it, expect } from 'vitest';
import { Field, getFieldMetadata, type FieldMeta } from '../../src/core/schema/field';
import { Input, Output } from '../../src/core/usecase';

// ── Test DTOs with example values ──────────────────────────────

class ExampleInput extends Input {
  @Field.string({ description: 'User name', example: 'Alice' })
  name!: string;

  @Field.integer({ description: 'User age', example: 30 })
  age!: number;

  @Field.number({ description: 'Score', example: 9.5 })
  score!: number;

  @Field.boolean({ description: 'Active?', example: true })
  active!: boolean;

  @Field.array(Field.string(), { description: 'Tags', example: ['dart', 'ts'] })
  tags!: string[];

  static fromJson(json: Record<string, unknown>): ExampleInput {
    const i = new ExampleInput();
    i.name = json['name'] as string;
    i.age = json['age'] as number;
    i.score = json['score'] as number;
    i.active = json['active'] as boolean;
    i.tags = json['tags'] as string[];
    return i;
  }
}

class ExampleOutput extends Output {
  @Field.string({ description: 'Greeting', example: 'Hello Alice' })
  greeting!: string;

  get statusCode() {
    return 200;
  }
}

// ── Tests ──────────────────────────────────────────────────────

describe('@Field example metadata', () => {
  it('stores example on string field', () => {
    const fields = getFieldMetadata(ExampleInput);
    const nameField = fields.find(f => f.name === 'name');
    expect(nameField?.example).toBe('Alice');
  });

  it('stores example on integer field', () => {
    const fields = getFieldMetadata(ExampleInput);
    const ageField = fields.find(f => f.name === 'age');
    expect(ageField?.example).toBe(30);
  });

  it('stores example on number field', () => {
    const fields = getFieldMetadata(ExampleInput);
    const scoreField = fields.find(f => f.name === 'score');
    expect(scoreField?.example).toBe(9.5);
  });

  it('stores example on boolean field', () => {
    const fields = getFieldMetadata(ExampleInput);
    const activeField = fields.find(f => f.name === 'active');
    expect(activeField?.example).toBe(true);
  });

  it('stores example on array field', () => {
    const fields = getFieldMetadata(ExampleInput);
    const tagsField = fields.find(f => f.name === 'tags');
    expect(tagsField?.example).toEqual(['dart', 'ts']);
  });
});

describe('buildSchemaFromMetadata with example', () => {
  it('emits per-property example in schema', () => {
    const schema = new ExampleInput().toSchema();
    const props = schema['properties'] as Record<string, Record<string, unknown>>;
    expect(props['name']['example']).toBe('Alice');
    expect(props['age']['example']).toBe(30);
    expect(props['score']['example']).toBe(9.5);
    expect(props['active']['example']).toBe(true);
    expect(props['tags']['example']).toEqual(['dart', 'ts']);
  });

  it('emits top-level example object', () => {
    const schema = new ExampleInput().toSchema();
    expect(schema['example']).toEqual({
      name: 'Alice',
      age: 30,
      score: 9.5,
      active: true,
      tags: ['dart', 'ts'],
    });
  });

  it('Output schema also has example', () => {
    const schema = new ExampleOutput().toSchema();
    const props = schema['properties'] as Record<string, Record<string, unknown>>;
    expect(props['greeting']['example']).toBe('Hello Alice');
    expect(schema['example']).toEqual({ greeting: 'Hello Alice' });
  });

  it('schemas without example omit the example key', () => {
    // FieldOptions without example → no example in schema
    class NoExampleInput extends Input {
      @Field.string({ description: 'Just a name' })
      name!: string;
    }
    const schema = new NoExampleInput().toSchema();
    const props = schema['properties'] as Record<string, Record<string, unknown>>;
    expect(props['name']).not.toHaveProperty('example');
    expect(schema).not.toHaveProperty('example');
  });
});
