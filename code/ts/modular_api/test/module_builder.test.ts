import { describe, it, expect, afterEach } from 'vitest';
import { Input, Output, UseCase, ModuleBuilder } from '../src';
import { apiRegistry } from '../src/core/registry';
import { Router } from 'express';

// ── Stubs: mirrors the example HelloWorld pattern ────────────

class GreetInput extends Input {
  readonly name: string;

  constructor(name = '') {
    super();
    this.name = name;
  }

  static fromJson(json: Record<string, unknown>): GreetInput {
    return new GreetInput((json['name'] ?? '').toString());
  }

  toJson() {
    return { name: this.name };
  }

  toSchema() {
    return {
      type: 'object',
      properties: {
        name: { type: 'string', description: 'Name to greet' },
      },
      required: ['name'],
    };
  }
}

class GreetOutput extends Output {
  readonly message: string;

  constructor(message = '') {
    super();
    this.message = message;
  }

  get statusCode() {
    return 200;
  }

  toJson() {
    return { message: this.message };
  }

  toSchema() {
    return {
      type: 'object',
      properties: {
        message: { type: 'string', description: 'Greeting message' },
      },
      required: ['message'],
    };
  }
}

/**
 * UseCase with output initialised to a default in constructor — same pattern as
 * Dart's HelloWorld. Enables framework schema extraction via factory({}).
 */
class UninitOutputUseCase extends UseCase<GreetInput, GreetOutput> {
  readonly input: GreetInput;

  constructor(input: GreetInput) {
    super();
    this.input = input;
  }

  static fromJson(json: Record<string, unknown>): UninitOutputUseCase {
    return new UninitOutputUseCase(GreetInput.fromJson(json));
  }

  validate() {
    return null;
  }

  async execute() {
    return new GreetOutput(`Hello, ${this.input.name}!`);
  }
}

// ── Tests ────────────────────────────────────────────────────

describe('ModuleBuilder schema extraction', () => {
  afterEach(() => {
    apiRegistry.clear();
  });

  it('captures Input schema from inputSchema override', () => {
    const builder = new ModuleBuilder('/api', 'greetings', Router());
    builder.usecase('hello', UninitOutputUseCase.fromJson, {
      inputClass: GreetInput as any,
      outputClass: GreetOutput as any,
      inputSchema: new GreetInput('').toSchema(),
      outputSchema: new GreetOutput('').toSchema(),
    });

    const registration = apiRegistry.routes[0];
    expect(registration.schemas.input).toHaveProperty('properties');
    expect(registration.schemas.input.properties).toHaveProperty('name');
  });

  it('input schema properties.name.type is string', () => {
    const builder = new ModuleBuilder('/api', 'greetings', Router());
    builder.usecase('hello', UninitOutputUseCase.fromJson, {
      inputClass: GreetInput as any,
      outputClass: GreetOutput as any,
      inputSchema: new GreetInput('').toSchema(),
      outputSchema: new GreetOutput('').toSchema(),
    });

    const inputSchema = apiRegistry.routes[0].schemas.input as Record<string, unknown>;
    const properties = inputSchema.properties as Record<string, Record<string, unknown>>;
    expect(properties.name.type).toBe('string');
  });

  it('captures Output schema from outputSchema override', () => {
    const builder = new ModuleBuilder('/api', 'greetings', Router());
    builder.usecase('hello', UninitOutputUseCase.fromJson, {
      inputClass: GreetInput as any,
      outputClass: GreetOutput as any,
      inputSchema: new GreetInput('').toSchema(),
      outputSchema: new GreetOutput('').toSchema(),
    });

    const outputSchema = apiRegistry.routes[0].schemas.output as Record<string, unknown>;
    expect(outputSchema).toHaveProperty('properties');

    const properties = outputSchema.properties as Record<string, Record<string, unknown>>;
    expect(properties).toHaveProperty('message');
    expect(properties.message.type).toBe('string');
  });
});
