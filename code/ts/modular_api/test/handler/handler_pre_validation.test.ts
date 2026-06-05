import { describe, it, expect, vi } from 'vitest';
import express from 'express';
import request from 'supertest';
import { Input, Output, UseCase, type UseCaseFactory } from '../../src/core/usecase';
import { Field } from '../../src/core/schema/field';
import { useCaseHandler } from '../../src/core/usecase_handler';

// ── Strict UseCase: fromJson THROWS on missing/wrong types ──

class StrictInput extends Input {
  @Field.string({ description: 'User name', example: 'Alice' })
  name!: string;

  @Field.integer({ description: 'User age', example: 30 })
  age!: number;

  @Field.number({ description: 'Score', example: 9.5 })
  score!: number;

  @Field.boolean({ description: 'Active?', example: true })
  active!: boolean;

  @Field.array(Field.string(), { description: 'Tags', example: ['dart'] })
  tags!: string[];

  static fromJson(json: Record<string, unknown>): StrictInput {
    const i = new StrictInput();
    // Strict — no coercion, will throw on wrong types
    i.name = json['name'] as string;
    i.age = json['age'] as number;
    i.score = json['score'] as number;
    i.active = json['active'] as boolean;
    i.tags = json['tags'] as string[];
    return i;
  }
}

class StrictOutput extends Output {
  @Field.string({ description: 'Greeting', example: 'Hello Alice' })
  greeting!: string;

  get statusCode() {
    return 200;
  }
}

class StrictUseCase extends UseCase<StrictInput, StrictOutput> {
  readonly input: StrictInput;

  constructor(input: StrictInput) {
    super();
    this.input = input;
  }

  static fromJson(json: Record<string, unknown>): StrictUseCase {
    return new StrictUseCase(StrictInput.fromJson(json));
  }

  validate() {
    return null;
  }

  async execute() {
    const out = new StrictOutput();
    out.greeting = `Hello ${this.input.name}`;
    return out;
  }
}

// ── Express app helpers ──

function makeApp(handler: express.RequestHandler) {
  const app = express();
  app.use(express.json());
  app.post('/test', handler);
  return app;
}

// ── Tests ──

describe('Handler pre-validation with inputClass', () => {
  const app = makeApp(
    useCaseHandler(StrictUseCase.fromJson as UseCaseFactory, {
      inputClass: StrictInput,
    }),
  );

  it('returns 400 when required field is missing', async () => {
    const res = await request(app)
      .post('/test')
      .send({ age: 30, score: 9.5, active: true, tags: ['dart'] });

    expect(res.status).toBe(400);
    expect(res.body.error).toContain('Missing required field: name');
  });

  it('returns 400 when string field receives int', async () => {
    const res = await request(app)
      .post('/test')
      .send({ name: 123, age: 30, score: 9.5, active: true, tags: ['dart'] });

    expect(res.status).toBe(400);
    expect(res.body.error).toContain("Field 'name' must be of type string");
  });

  it('returns 400 when integer field receives string', async () => {
    const res = await request(app)
      .post('/test')
      .send({ name: 'Alice', age: 'thirty', score: 9.5, active: true, tags: ['dart'] });

    expect(res.status).toBe(400);
    expect(res.body.error).toContain("Field 'age' must be of type integer");
  });

  it('returns 400 when number field receives string', async () => {
    const res = await request(app)
      .post('/test')
      .send({ name: 'Alice', age: 30, score: 'high', active: true, tags: ['dart'] });

    expect(res.status).toBe(400);
    expect(res.body.error).toContain("Field 'score' must be of type number");
  });

  it('returns 400 when boolean field receives string', async () => {
    const res = await request(app)
      .post('/test')
      .send({ name: 'Alice', age: 30, score: 9.5, active: 'yes', tags: ['dart'] });

    expect(res.status).toBe(400);
    expect(res.body.error).toContain("Field 'active' must be of type boolean");
  });

  it('returns 400 when array field receives string', async () => {
    const res = await request(app)
      .post('/test')
      .send({ name: 'Alice', age: 30, score: 9.5, active: true, tags: 'dart' });

    expect(res.status).toBe(400);
    expect(res.body.error).toContain("Field 'tags' must be of type array");
  });

  it('returns 200 with valid data (strict fromJson works)', async () => {
    const res = await request(app)
      .post('/test')
      .send({ name: 'Alice', age: 30, score: 9.5, active: true, tags: ['dart'] });

    expect(res.status).toBe(200);
    expect(res.body.greeting).toBe('Hello Alice');
  });

  it('returns 400 on empty body (first missing field)', async () => {
    const res = await request(app)
      .post('/test')
      .send({});

    expect(res.status).toBe(400);
    expect(res.body.error).toContain('Missing required field');
  });

  it('pre-validates BEFORE fromJson — factory is never called on invalid data', async () => {
    let factoryCalled = false;
    const crashingFactory: UseCaseFactory = (_json) => {
      factoryCalled = true;
      throw new Error('factory should not be called');
    };

    const appCrash = makeApp(
      useCaseHandler(crashingFactory, { inputClass: StrictInput }),
    );
    const res = await request(appCrash).post('/test').send({});

    expect(res.status).toBe(400);
    expect(factoryCalled).toBe(false);
  });
});

describe('Handler backward-compat — no inputClass', () => {
  it('without inputClass, still validates via post-validation (lenient factory)', async () => {
    // TS handler currently always post-validates — but with lenient fromJson it works
    const app = makeApp(useCaseHandler(StrictUseCase.fromJson as UseCaseFactory));

    // With strict fromJson + no inputClass, wrong type causes crash → 500
    const res = await request(app)
      .post('/test')
      .send({ name: 123, age: 30, score: 9.5, active: true, tags: ['dart'] });

    // If name is 123 (number), `as string` still "works" in JS (no crash),
    // but validateJson after factory catches the type mismatch → 400
    // Actually in JS, `as string` is erased at runtime. So name === 123 and
    // post-validation catches it. This demonstrates backward-compat still works.
    expect(res.status).toBe(400);
  });
});
