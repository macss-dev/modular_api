# Testing Guide

This guide covers how to test `UseCase` classes in **modular_api**.  
The recommended approach is **constructor-based injection** with fake adapters.

---

## Unit tests — constructor injection (recommended)

Inject fake implementations of your dependencies directly through the `UseCase`
constructor. This keeps tests fast, deterministic, and free of any real
infrastructure (databases, HTTP services, etc.).

```ts
import { describe, it, expect, beforeEach } from 'vitest';
import { UseCaseException } from 'modular_api';

// ─── Fakes ──────────────────────────────────────────────────
class FakeImcRepository implements ImcRepository {
  registros: Array<{ id: string; imc: number; categoria: string }> = [];

  async guardarResultado(params: {
    peso: number;
    altura: number;
    imc: number;
    categoria: string;
  }): Promise<string> {
    const id = `test_${this.registros.length + 1}`;
    this.registros.push({ id, imc: params.imc, categoria: params.categoria });
    return id;
  }
}

class FakeFailingRepo implements ImcRepository {
  async guardarResultado(): Promise<string> {
    throw new Error('DB unavailable');
  }
}

// ─── Tests ──────────────────────────────────────────────────
describe('CalcularImc', () => {
  let fakeRepo: FakeImcRepository;

  beforeEach(() => {
    fakeRepo = new FakeImcRepository();
  });

  it('calcula IMC correctamente', async () => {
    // ✅ Inject fake directly through the constructor
    const usecase = new CalcularImc(new CalcularImcInput(70.0, 1.75), { repository: fakeRepo });

    expect(usecase.validate()).toBeNull();

    const output = await usecase.execute();

    expect(output.imc).toBeCloseTo(22.86, 1);
    expect(output.categoria).toBe('Normal');
    expect(fakeRepo.registros).toHaveLength(1);
    expect(fakeRepo.registros[0].categoria).toBe('Normal');
  });

  it('rechaza peso negativo', () => {
    const usecase = new CalcularImc(new CalcularImcInput(-5.0, 1.75), { repository: fakeRepo });

    expect(usecase.validate()).toContain('positivo');
  });

  it('lanza UseCaseException cuando el repo falla', async () => {
    const usecase = new CalcularImc(new CalcularImcInput(70.0, 1.75), {
      repository: new FakeFailingRepo(),
    });

    await expect(usecase.execute()).rejects.toThrow(UseCaseException);
  });
});
```

### Why constructor injection?

| Concern          | Constructor (unit)  | `fromJson` (integration) |
| ---------------- | ------------------- | ------------------------ |
| Speed            | Milliseconds        | Seconds (network I/O)    |
| Reliability      | Always green        | Depends on infra         |
| Isolation        | Pure business logic | End-to-end               |
| Fake support     | ✅ Full control     | ❌ Uses prod adapters    |
| State inspection | ✅ Query fake state | ❌ Not possible          |

---

## Integration tests — `fromJson` directly

When you intentionally want to test against real infrastructure, call
`UseCase.fromJson()` directly. No helper wrapper is required.

```ts
it('integration — persists to real DB', async () => {
  const usecase = CalcularImc.fromJson({ peso: 70.0, altura: 1.75 });

  expect(usecase.validate()).toBeNull();

  const output = await usecase.execute();

  expect(output.imc).toBeCloseTo(22.86, 1);
});
```

> **Note:** Integration tests require the real infrastructure (database,
> external APIs, etc.) to be available. Keep them in a separate test suite
> and exclude them from your standard CI unit-test run.

---

## Vitest 4.x — configuring OXC for `@Field` decorators

Vitest 4.x uses [OXC](https://oxc.rs/) instead of esbuild for TypeScript
transformation. OXC reads `tsconfig.json` to decide how to handle decorators.
The `@Field.*` decorators in modular-api are **TC39 decorators** (stage 3), so
the main `tsconfig.json` does **not** set `experimentalDecorators`. However, OXC
fails to parse `@Field.integer()` and similar expressions without that flag,
producing a `SyntaxError: Invalid or unexpected token` at import time.

**Solution:** create a separate `tsconfig.test.json` that enables
`experimentalDecorators` only for the test runner, and point vitest to it.

### 1. `tsconfig.test.json`

```json
{
  "extends": "./tsconfig.json",
  "compilerOptions": {
    "experimentalDecorators": true
  },
  "include": ["src/**/*", "tests/**/*"]
}
```

### 2. `vitest.config.ts`

```ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  oxc: {
    tsconfig: {
      configFile: './tsconfig.test.json',
    },
  },
  test: {
    root: '.',
  },
});
```

### 3. Mock `@macss/modular-api` when testing with `vi.mock`

When unit-testing a `UseCase` class via `vi.mock` + dynamic `await import()`
(instead of constructor injection), you must mock the decorators so OXC can
resolve the `@Field.*` calls:

```ts
vi.mock('@macss/modular-api', () => {
  const noopDecorator = () => (_target: any, _key: string) => {};
  return {
    Input: class {},
    Output: class {},
    UseCase: class {},
    Field: {
      integer: () => noopDecorator(),
      boolean: () => noopDecorator(),
      string:  () => noopDecorator(),
    },
    UseCaseException: class extends Error {
      statusCode: number;
      constructor(params: { statusCode: number; message: string }) {
        super(params.message);
        this.statusCode = params.statusCode;
      }
    },
  };
});

const { MyUseCase } = await import('../../src/modules/my-use-case');
```

> **Important:** `noopDecorator` must be defined **inside** the `vi.mock()`
> factory callback. Vitest hoists `vi.mock()` calls to the top of the file,
> so any variable declared outside the factory is `undefined` when it runs.

> **Prefer constructor injection** (see above) whenever possible — it avoids
> the mock entirely. The `vi.mock` approach is only needed when the use case
> lacks constructor-based dependency injection or when you need to mock
> multiple sibling modules that the use case imports.

---

## Summary

| Test type       | When to use              | How                                              |
| --------------- | ------------------------ | ------------------------------------------------ |
| **Unit**        | Default — always         | `new MyUseCase(input, { repository: fakeRepo })` |
| **Integration** | Verify real infra wiring | `MyUseCase.fromJson(json)` directly              |
