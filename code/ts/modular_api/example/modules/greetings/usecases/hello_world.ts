import { Input, Output, UseCase, Field, ModularLogger } from '../../../../src/index';

// ─── Input DTO ────────────────────────────────────────────────────────────────

export class HelloWorldInput extends Input {
  @Field.string({ description: 'Name to greet', example: 'World' })
  name!: string;
}

// ─── Output DTO ───────────────────────────────────────────────────────────────

export class HelloWorldOutput extends Output {
  @Field.string({ description: 'Greeting message', example: 'Hello, World!' })
  message!: string;

  get statusCode() {
    return 200;
  }
}

// ─── UseCase ──────────────────────────────────────────────────────────────────

export class HelloWorld implements UseCase<HelloWorldInput, HelloWorldOutput> {
  readonly input: HelloWorldInput;
  logger?: ModularLogger;

  constructor(input: HelloWorldInput) {
    this.input = input;
  }

  static fromJson(json: Record<string, unknown>): HelloWorld {
    const input = new HelloWorldInput();
    input.name = json['name'] as string;
    return new HelloWorld(input);
  }

  validate(): string | null {
    if (!this.input.name) {
      return 'name is required';
    }
    return null;
  }

  async execute(): Promise<HelloWorldOutput> {
    this.logger?.info(`Greeting user: ${this.input.name}`);
    const output = new HelloWorldOutput();
    output.message = `Hello, ${this.input.name}!`;
    return output;
  }
}
