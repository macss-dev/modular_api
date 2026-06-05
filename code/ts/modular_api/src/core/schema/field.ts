// ============================================================
// core/schema/field.ts
// Stage 3 decorators that store OpenAPI-compatible field metadata.
//
// Usage:
//   class HelloInput extends Input {
//     @Field.string({ description: 'Name to greet' })
//     name!: string;
//
//     @Field.optional(Field.integer({ description: 'Age' }))
//     age?: number;
//   }
//
// At runtime, `getFieldMetadata(HelloInput)` returns the list of
// FieldMeta entries in declaration order, which Input.toSchema()
// uses to build an OpenAPI 3.0.3-compatible JSON Schema.
// ============================================================

// Polyfill for runtimes that lack Symbol.metadata (Node < 22)
declare global {
  interface SymbolConstructor {
    readonly metadata: unique symbol;
  }
}
(Symbol as unknown as Record<string, unknown>).metadata ??= Symbol('Symbol.metadata');

/** Metadata stored per decorated field. */
export interface FieldMeta {
  name: string;
  type: 'string' | 'integer' | 'number' | 'boolean' | 'array' | 'object';
  description?: string;
  required: boolean;
  nullable: boolean;
  items?: { type: string };
  example?: unknown;
}

/** Options accepted by every primitive Field decorator. */
export interface FieldOptions {
  description?: string;
  example?: unknown;
}

// ── Internal storage key ─────────────────────────────────────

const FIELD_KEY = Symbol('FieldMeta');

// ── Stage 3 class field decorator factory ────────────────────

type FieldDecorator = (
  value: undefined,
  context: ClassFieldDecoratorContext,
) => void;

function makeFieldDecorator(
  type: FieldMeta['type'],
  options: FieldOptions = {},
  extra: Partial<FieldMeta> = {},
): FieldDecorator {
  return function (_value: undefined, context: ClassFieldDecoratorContext): void {
    const meta: FieldMeta = {
      name: String(context.name),
      type,
      description: options.description,
      required: true,
      nullable: false,
      ...extra,
    };
    if (options.example !== undefined) {
      meta.example = options.example;
    }

    const metadata = context.metadata as Record<symbol, FieldMeta[]>;
    if (!metadata[FIELD_KEY]) {
      metadata[FIELD_KEY] = [];
    }
    metadata[FIELD_KEY].push(meta);
  };
}

// ── Wrapper for optional fields ──────────────────────────────

/** Internal marker returned by primitive Field methods for use with Field.optional(). */
interface PendingField {
  __pending: true;
  type: FieldMeta['type'];
  options: FieldOptions;
  extra: Partial<FieldMeta>;
}

// ── Public API ───────────────────────────────────────────────

export const Field = {
  string(options: FieldOptions = {}): FieldDecorator & PendingField {
    const decorator = makeFieldDecorator('string', options);
    return Object.assign(decorator, { __pending: true as const, type: 'string' as const, options, extra: {} });
  },

  integer(options: FieldOptions = {}): FieldDecorator & PendingField {
    const decorator = makeFieldDecorator('integer', options);
    return Object.assign(decorator, { __pending: true as const, type: 'integer' as const, options, extra: {} });
  },

  number(options: FieldOptions = {}): FieldDecorator & PendingField {
    const decorator = makeFieldDecorator('number', options);
    return Object.assign(decorator, { __pending: true as const, type: 'number' as const, options, extra: {} });
  },

  boolean(options: FieldOptions = {}): FieldDecorator & PendingField {
    const decorator = makeFieldDecorator('boolean', options);
    return Object.assign(decorator, { __pending: true as const, type: 'boolean' as const, options, extra: {} });
  },

  object(options: FieldOptions = {}): FieldDecorator & PendingField {
    const decorator = makeFieldDecorator('object', options);
    return Object.assign(decorator, { __pending: true as const, type: 'object' as const, options, extra: {} });
  },

  /**
   * Marks a field as optional (nullable, not required).
   *
   * ```ts
   * @Field.optional(Field.string({ description: 'Nickname' }))
   * nickname?: string;
   * ```
   */
  optional(inner: PendingField): FieldDecorator {
    return makeFieldDecorator(inner.type, inner.options, {
      ...inner.extra,
      required: false,
      nullable: true,
    });
  },

  /**
   * Array field with typed items.
   *
   * ```ts
   * @Field.array(Field.string(), { description: 'tags' })
   * tags!: string[];
   * ```
   */
  array(itemType: PendingField, options: FieldOptions = {}): FieldDecorator & PendingField {
    const extra: Partial<FieldMeta> = { items: { type: itemType.type } };
    const decorator = makeFieldDecorator('array', options, extra);
    return Object.assign(decorator, { __pending: true as const, type: 'array' as const, options, extra });
  },
};

// ── Public accessor ──────────────────────────────────────────

/**
 * Retrieves the `@Field` metadata registered on a class.
 * Returns an empty array if the class has no decorated fields.
 */
export function getFieldMetadata(target: abstract new (...args: unknown[]) => unknown): FieldMeta[] {
  const metadata = (target as unknown as Record<symbol, Record<symbol, FieldMeta[]>>)[Symbol.metadata];
  return metadata?.[FIELD_KEY] ?? [];
}
