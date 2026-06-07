import { Input, Output, UseCase, Field, ModularLogger } from '../../../../src/index';

// ─── Input DTO ────────────────────────────────────────────────────────────────

export class CurrentTimeInput extends Input {
  @Field.optional(Field.string({ description: 'Timezone offset (e.g. utc-5, utc+3, utc)', example: 'utc-5' }))
  tz?: string;
}

// ─── Output DTO ───────────────────────────────────────────────────────────────

export class CurrentTimeOutput extends Output {
  @Field.string({ description: 'ISO 8601 datetime at the requested offset', example: '2026-03-14T07:00:00' })
  datetime!: string;

  @Field.integer({ description: 'UTC offset in hours', example: -5 })
  offset!: number;

  get statusCode() {
    return 200;
  }
}

// ─── UseCase ──────────────────────────────────────────────────────────────────

export class CurrentTime implements UseCase<CurrentTimeInput, CurrentTimeOutput> {
  readonly input: CurrentTimeInput;
  logger?: ModularLogger;

  constructor(input: CurrentTimeInput) {
    this.input = input;
  }

  static fromJson(json: Record<string, unknown>): CurrentTime {
    const input = new CurrentTimeInput();
    input.tz = json['tz'] != null ? String(json['tz']) : undefined;
    return new CurrentTime(input);
  }

  validate(): string | null {
    if (!this.input.tz) return null;
    const offset = CurrentTime.parseOffset(this.input.tz);
    if (offset === null) return 'invalid timezone format, use utc, utc-5, utc+3';
    if (offset < -12 || offset > 14) return 'offset must be between -12 and +14';
    return null;
  }

  async execute(): Promise<CurrentTimeOutput> {
    const now = new Date();
    const offsetHours = this.input.tz
      ? CurrentTime.parseOffset(this.input.tz)!
      : -(now.getTimezoneOffset() / 60);
    const adjusted = new Date(now.getTime() + offsetHours * 3600_000);
    const iso = adjusted.toISOString().split('.')[0];

    this.logger?.info(`Time requested for offset ${offsetHours}`);
    const output = new CurrentTimeOutput();
    output.datetime = iso;
    output.offset = offsetHours;
    return output;
  }

  /** Parses "utc-5", "utc+3", "utc" into an integer offset. Returns null on bad format. */
  private static parseOffset(tz: string): number | null {
    const lower = tz.toLowerCase().trim();
    if (lower === 'utc') return 0;
    const match = lower.match(/^utc([+-]\d{1,2})$/);
    if (!match) return null;
    return parseInt(match[1], 10);
  }
}
