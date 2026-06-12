# Testing Guide

How to test `UseCase` classes in modular_api. The recommended approach is
**constructor-based injection** with fake adapters — identical across the three
SDKs; TypeScript examples below, Dart/Python parity notes at the end.

## Unit tests — constructor injection (recommended)

Inject fake implementations of your dependencies directly through the `UseCase`
constructor. This keeps tests fast, deterministic, and free of any real
infrastructure (databases, HTTP services, etc.).

```ts
import { describe, it, expect, beforeEach } from 'vitest';
import { UseCaseException } from '@macss/modular-api';

// --- Fakes -------------------------------------------------------
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

// --- Tests -------------------------------------------------------
describe('CalcularImc', () => {
  let fakeRepo: FakeImcRepository;

  beforeEach(() => {
    fakeRepo = new FakeImcRepository();
  });

  it('computes IMC correctly', async () => {
    // Inject the fake directly through the constructor
    const usecase = new CalcularImc(new CalcularImcInput(70.0, 1.75), { repository: fakeRepo });

    expect(usecase.validate()).toBeNull();

    const output = await usecase.execute();

    expect(output.imc).toBeCloseTo(22.86, 1);
    expect(output.categoria).toBe('Normal');
    expect(fakeRepo.registros).toHaveLength(1);
    expect(fakeRepo.registros[0].categoria).toBe('Normal');
  });

  it('rejects negative weight', () => {
    const usecase = new CalcularImc(new CalcularImcInput(-5.0, 1.75), { repository: fakeRepo });

    expect(usecase.validate()).toContain('positivo');
  });

  it('throws UseCaseException when the repo fails', async () => {
    const usecase = new CalcularImc(new CalcularImcInput(70.0, 1.75), {
      repository: new FakeFailingRepo(),
    });

    await expect(usecase.execute()).rejects.toThrow(UseCaseException);
  });
});
```

### Why constructor injection?

| Concern | Constructor (unit) | `fromJson` (integration) |
|---|---|---|
| Speed | Milliseconds | Seconds (network I/O) |
| Reliability | Always green | Depends on infra |
| Isolation | Pure business logic | End-to-end |
| Fake support | Full control | Uses prod adapters |
| State inspection | Query fake state | Not possible |

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

Integration tests require the real infrastructure to be available. Keep them in a
separate suite and exclude them from the standard CI unit-test run.

## Vitest setup for `@Field` decorators (TypeScript)

This section replaces the previously documented "Vitest 4.x — configuring OXC"
recipe, which is **broken** and closed by issue
[#19](https://github.com/ccisnedev/modular_api/issues/19).

### The verified working setup

Use **vitest 4.0.x with standard vite 7** (esbuild transform). No transform
options are needed, and `experimentalDecorators` must NOT appear in ANY tsconfig:

```jsonc
// package.json (devDependencies)
{
  "vitest": "^4.0.18"
  // resolves standard vite 7.x — do not switch to rolldown-vite
}
```

```ts
// vitest.config.ts — no oxc/transform options
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['test/**/*.test.ts'],
  },
});
```

```jsonc
// tsconfig.json — and every tsconfig the project extends or references
{
  "compilerOptions": {
    // "experimentalDecorators": true  <-- must NOT be present anywhere
  }
}
```

This is exactly how the SDK itself is configured (vitest 4.0.x on vite 7.3.1,
plain `vitest.config.ts`, no `experimentalDecorators` in any tsconfig), and it is
the configuration validated by the first real consumer.

### Why the old OXC recipe is broken

The old guide recommended `oxc.tsconfig.configFile` pointing at a
`tsconfig.test.json` with `experimentalDecorators: true`. Two independent problems:

1. **The option is silently ignored.** In rolldown-vite (vite 8), `OxcOptions`
   does `Omit<..., 'tsconfig'>` — the documented `tsconfig` key is stripped from
   the accepted options type and never reaches the transformer. The recipe
   appears configured but does nothing.
2. **OXC cannot compile `@Field` either way.** OXC does not support TC39 Stage 3
   decorators, so `@Field.string()` fails to parse (`SyntaxError`). Enabling
   `decorator.legacy: true` makes it parse but changes the decorator calling
   convention: the Stage 3 `context.metadata` channel is never populated and
   `@Field` blows up at runtime with `TypeError` mentioning `Symbol(FieldMeta)`.

Conclusion: do not use rolldown-vite/OXC with this SDK. Stay on vitest 4.0.x with
standard vite 7 and zero transform configuration. See [pitfalls.md](../pitfalls.md)
rows 1 and 2 for the symptom-to-fix mapping.

### Mocking `@macss/modular-api` with `vi.mock`

When unit-testing a `UseCase` via `vi.mock` + dynamic `await import()` (instead of
constructor injection), mock the decorators:

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

`noopDecorator` must be defined **inside** the `vi.mock()` factory callback —
vitest hoists `vi.mock()` calls to the top of the file, so any variable declared
outside the factory is `undefined` when it runs.

Prefer constructor injection whenever possible — it avoids the mock entirely. The
`vi.mock` approach is only needed when the use case lacks constructor-based
dependency injection or when you need to mock multiple sibling modules.

### Testing with the logger

```ts
import { useCaseTestHandler, RequestScopedLogger, LogLevel } from '@macss/modular-api';

const lines: string[] = [];
const logger = new RequestScopedLogger({
  traceId: 'test-trace',
  serviceName: 'test',
  logLevel: LogLevel.debug,
  writeFn: (line) => lines.push(line),
});

const response = await useCaseTestHandler(MyUseCase.fromJson, { name: 'World' }, { logger });

expect(response.statusCode).toBe(200);
expect(lines.some((l) => l.includes('test-trace'))).toBe(true);
```

## Dart parity notes

Same pattern with `package:test`. Inject fakes through the constructor; assert on
`useCase.output` and on fake state:

```dart
test('should sum two positive numbers', () async {
  final useCase = SumNumbers(SumInput(a: 5, b: 3), repository: fakeRepo);

  expect(useCase.validate(), isNull);
  await useCase.execute();

  expect(useCase.output.result, equals(8));
  expect(fakeRepo.savedResults, equals([8]));
});

test('should throw UseCaseException when repository fails', () {
  final useCase = SumNumbers(SumInput(a: 5, b: 3), repository: FakeFailingRepository());
  expect(() => useCase.execute(), throwsA(isA<UseCaseException>()));
});
```

Run with `dart test` (coverage via `dart test --coverage=coverage`).

## Python parity notes

Same pattern with pytest + `pytest-asyncio`:

```python
async def test_hello_world():
    usecase = HelloWorld(HelloInput(name="World"), repository=fake_repo)
    assert usecase.validate() is None

    output = await usecase.execute()
    assert output.message == "Hello, World!"
```

## Summary

| Test type | When to use | How |
|---|---|---|
| Unit | Default — always | `new MyUseCase(input, { repository: fakeRepo })` |
| Integration | Verify real infra wiring | `MyUseCase.fromJson(json)` directly |

Best practices: inject fakes via constructor (never `fromJson` in unit tests);
assert on output AND side effects (fake state); test both success and failure
paths; keep integration suites separate from CI unit runs.
