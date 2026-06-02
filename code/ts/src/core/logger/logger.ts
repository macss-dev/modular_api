// ============================================================
// core/logger/logger.ts
// LogLevel enum, ModularLogger interface, RequestScopedLogger.
// Mirror of logger.dart — RFC 5424, JSON to stdout, zero deps.
// ============================================================

/**
 * RFC 5424 log levels in descending severity order.
 *
 * Filtering rule: if configured `logLevel = X`, only messages with
 * `value <= X` are emitted. Higher values produce total silence.
 */
export enum LogLevel {
  emergency = 0, // system unusable
  alert = 1, // immediate action required
  critical = 2, // critical condition
  error = 3, // operation error, 5xx
  warning = 4, // abnormal condition, 4xx
  notice = 5, // normal but significant
  info = 6, // normal flow, 2xx/3xx
  debug = 7, // detailed diagnostics
}

/** Human-readable name for each LogLevel value. */
const LEVEL_NAME: Record<LogLevel, string> = {
  [LogLevel.emergency]: 'emergency',
  [LogLevel.alert]: 'alert',
  [LogLevel.critical]: 'critical',
  [LogLevel.error]: 'error',
  [LogLevel.warning]: 'warning',
  [LogLevel.notice]: 'notice',
  [LogLevel.info]: 'info',
  [LogLevel.debug]: 'debug',
};

/**
 * Public logger interface exposed to UseCases.
 *
 * Each method corresponds to an RFC 5424 severity level.
 * `fields` is an optional map of structured data attached to the log entry.
 */
export interface ModularLogger {
  /** Request-scoped trace ID for correlation. */
  readonly traceId: string;
  emergency(msg: string, fields?: Record<string, unknown>): void;
  alert(msg: string, fields?: Record<string, unknown>): void;
  critical(msg: string, fields?: Record<string, unknown>): void;
  error(msg: string, fields?: Record<string, unknown>): void;
  warning(msg: string, fields?: Record<string, unknown>): void;
  notice(msg: string, fields?: Record<string, unknown>): void;
  info(msg: string, fields?: Record<string, unknown>): void;
  debug(msg: string, fields?: Record<string, unknown>): void;
}

/** Function signature for the output sink — defaults to `console.log`. */
export type WriteFn = (line: string) => void;

/**
 * Per-request logger that carries `traceId` and respects `logLevel` filtering.
 *
 * Created by `loggingMiddleware` for each incoming HTTP request and injected
 * into the UseCase via the `logger` property.
 *
 * Accepts an optional `writeFn` for output — defaults to `console.log`.
 * In tests, pass a capturing function to inspect output without side-effects.
 */
export class RequestScopedLogger implements ModularLogger {
  constructor(
    readonly traceId: string,
    readonly logLevel: LogLevel,
    readonly serviceName: string,
    private readonly writeFn: WriteFn = (line) => process.stdout.write(line + '\n'),
  ) {}

  // ─── Public API (8 RFC 5424 levels) ──────────────────────────────

  emergency(msg: string, fields?: Record<string, unknown>): void {
    this.log(LogLevel.emergency, msg, { fields });
  }
  alert(msg: string, fields?: Record<string, unknown>): void {
    this.log(LogLevel.alert, msg, { fields });
  }
  critical(msg: string, fields?: Record<string, unknown>): void {
    this.log(LogLevel.critical, msg, { fields });
  }
  error(msg: string, fields?: Record<string, unknown>): void {
    this.log(LogLevel.error, msg, { fields });
  }
  warning(msg: string, fields?: Record<string, unknown>): void {
    this.log(LogLevel.warning, msg, { fields });
  }
  notice(msg: string, fields?: Record<string, unknown>): void {
    this.log(LogLevel.notice, msg, { fields });
  }
  info(msg: string, fields?: Record<string, unknown>): void {
    this.log(LogLevel.info, msg, { fields });
  }
  debug(msg: string, fields?: Record<string, unknown>): void {
    this.log(LogLevel.debug, msg, { fields });
  }

  // ─── Framework-internal: request/response logging ────────────────

  /** Emits a "request received" log at `info` level. */
  logRequest(opts: { method: string; route: string }): void {
    this.log(LogLevel.info, 'request received', {
      extra: { method: opts.method, route: opts.route },
    });
  }

  /** Emits a "request completed" log at the level determined by `statusCode`. */
  logResponse(opts: {
    method: string;
    route: string;
    statusCode: number;
    durationMs: number;
    extra?: Record<string, unknown>;
  }): void {
    this.log(RequestScopedLogger.levelForStatus(opts.statusCode), 'request completed', {
      extra: {
        method: opts.method,
        route: opts.route,
        status: opts.statusCode,
        duration_ms: opts.durationMs,
        ...(opts.extra ?? {}),
      },
    });
  }

  /** Emits an "unhandled exception" log at `error` level. No stack trace. */
  logUnhandledException(opts: { route: string }): void {
    this.log(LogLevel.error, 'unhandled exception', {
      extra: { route: opts.route, status: 500 },
    });
  }

  // ─── Internal ────────────────────────────────────────────────────

  private log(
    level: LogLevel,
    msg: string,
    opts: {
      fields?: Record<string, unknown>;
      extra?: Record<string, unknown>;
    } = {},
  ): void {
    // Filtering: only emit if the message level <= configured logLevel.
    if (level > this.logLevel) return;

    const entry: Record<string, unknown> = {
      ts: Date.now() / 1000,
      level: LEVEL_NAME[level],
      severity: level as number,
      msg,
      service: this.serviceName,
      trace_id: this.traceId,
    };

    if (opts.extra) Object.assign(entry, opts.extra);
    if (opts.fields) entry['fields'] = opts.fields;

    this.writeFn(JSON.stringify(entry));
  }

  /** Maps HTTP status code → RFC 5424 log level. */
  static levelForStatus(status: number): LogLevel {
    if (status >= 500) return LogLevel.error;
    if (status >= 400) return LogLevel.warning;
    if (status >= 200 && status < 400) return LogLevel.info;
    return LogLevel.notice; // 1xx
  }
}
