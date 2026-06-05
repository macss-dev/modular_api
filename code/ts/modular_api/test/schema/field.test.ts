import { describe, it, expect } from 'vitest';
import { Field, getFieldMetadata, type FieldMeta } from '../../src/core/schema/field';

// ── Test classes ─────────────────────────────────────────────

class NameInput {
  @Field.string({ description: 'Name to greet' })
  name!: string;
}

class AgeInput {
  @Field.integer({ description: 'User age' })
  age!: number;
}

class MultiFieldInput {
  @Field.string({ description: 'First name' })
  firstName!: string;

  @Field.integer({ description: 'Birth year' })
  year!: number;

  @Field.boolean()
  active!: boolean;

  @Field.number({ description: 'Score' })
  score!: number;
}

class OptionalFieldInput {
  @Field.string({ description: 'Required name' })
  name!: string;

  @Field.optional(Field.string({ description: 'Optional nickname' }))
  nickname?: string;
}

class ArrayFieldInput {
  @Field.array(Field.string(), { description: 'List of tags' })
  tags!: string[];
}

// ── Tests ────────────────────────────────────────────────────

describe('@Field decorator metadata storage', () => {
  it('stores string field metadata', () => {
    const fields = getFieldMetadata(NameInput);
    expect(fields).toHaveLength(1);
    expect(fields[0]).toEqual<FieldMeta>({
      name: 'name',
      type: 'string',
      description: 'Name to greet',
      required: true,
      nullable: false,
    });
  });

  it('stores integer field metadata', () => {
    const fields = getFieldMetadata(AgeInput);
    expect(fields).toHaveLength(1);
    expect(fields[0]).toEqual<FieldMeta>({
      name: 'age',
      type: 'integer',
      description: 'User age',
      required: true,
      nullable: false,
    });
  });

  it('stores number field metadata', () => {
    const fields = getFieldMetadata(MultiFieldInput);
    const score = fields.find((f) => f.name === 'score');
    expect(score).toEqual<FieldMeta>({
      name: 'score',
      type: 'number',
      description: 'Score',
      required: true,
      nullable: false,
    });
  });

  it('stores boolean field metadata', () => {
    const fields = getFieldMetadata(MultiFieldInput);
    const active = fields.find((f) => f.name === 'active');
    expect(active).toEqual<FieldMeta>({
      name: 'active',
      type: 'boolean',
      description: undefined,
      required: true,
      nullable: false,
    });
  });

  it('stores multiple fields in declaration order', () => {
    const fields = getFieldMetadata(MultiFieldInput);
    expect(fields).toHaveLength(4);
    expect(fields.map((f) => f.name)).toEqual(['firstName', 'year', 'active', 'score']);
  });

  it('marks optional fields as not required and nullable', () => {
    const fields = getFieldMetadata(OptionalFieldInput);
    expect(fields).toHaveLength(2);

    const name = fields.find((f) => f.name === 'name');
    expect(name!.required).toBe(true);
    expect(name!.nullable).toBe(false);

    const nickname = fields.find((f) => f.name === 'nickname');
    expect(nickname!.required).toBe(false);
    expect(nickname!.nullable).toBe(true);
    expect(nickname!.description).toBe('Optional nickname');
  });

  it('stores array field metadata with items', () => {
    const fields = getFieldMetadata(ArrayFieldInput);
    expect(fields).toHaveLength(1);
    expect(fields[0]).toEqual<FieldMeta>({
      name: 'tags',
      type: 'array',
      description: 'List of tags',
      required: true,
      nullable: false,
      items: { type: 'string' },
    });
  });

  it('returns empty array for class with no decorators', () => {
    class PlainClass {
      foo = 42;
    }
    expect(getFieldMetadata(PlainClass)).toEqual([]);
  });
});
