# Structured JSON Logger

Request-scoped structured logging compatible with **Loki**, **Grafana**, **Elasticsearch**, and any JSON log aggregator.

Enabled by default. Every HTTP request gets a unique `trace_id` for end-to-end correlation.

---

## Quick start

```ts
const api = new ModularApi({
  basePath: '/api',
  title: 'My Service',
  logLevel: LogLevel.info, // default — emits emergency..info
});

await api.serve({ port: 8080 });
```

Every request now produces structured JSON logs to stdout:

```json
{"ts":1718000000.123,"level":"info","severity":6,"msg":"request received","service":"My Service","trace_id":"a1b2c3d4-...","method":"POST","route":"/api/greetings/hello"}
{"ts":1718000000.456,"level":"info","severity":6,"msg":"request completed","service":"My Service","trace_id":"a1b2c3d4-...","method":"POST","route":"/api/greetings/hello","status":200,"duration_ms":3.21}
```

---

## Log levels (RFC 5424)

| Level       | Value | When emitted                       |
| ----------- | ----- | ---------------------------------- |
| `emergency` | 0     | System unusable                    |
| `alert`     | 1     | Immediate action required          |
| `critical`  | 2     | Critical condition                 |
| `error`     | 3     | Operation errors, 5xx responses    |
| `warning`   | 4     | Abnormal conditions, 4xx responses |
| `notice`    | 5     | Normal but significant             |
| `info`      | 6     | Normal flow, 2xx/3xx responses     |
| `debug`     | 7     | Detailed diagnostics               |

**Filtering rule:** A message is emitted if `level.value <= logLevel.value`.

Setting `logLevel: LogLevel.warning` emits only emergency, alert, critical, error, and warning.

---

## Using the logger inside UseCases

The framework injects a request-scoped logger into every UseCase automatically via the `logger` property inherited from the abstract `UseCase` class.

```ts
class CreateUser extends UseCase<CreateUserInput, CreateUserOutput> {
  readonly input: CreateUserInput;
  output!: CreateUserOutput;

  constructor(input: CreateUserInput) {
    super();
    this.input = input;
  }

  static fromJson(json: Record<string, unknown>) {
    return new CreateUser(CreateUserInput.fromJson(json));
  }

  validate() {
    return null;
  }

  async execute(): Promise<CreateUserOutput> {
    this.logger?.info(`Creating user: ${this.input.email}`);

    // ... business logic ...

    this.logger?.debug('User created successfully', {
      userId: newUser.id,
      email: this.input.email,
    });

    return new CreateUserOutput(newUser.id);
  }
}
```

### Logger methods

Each method corresponds to an RFC 5424 level:

```ts
this.logger?.emergency('System is down');
this.logger?.alert('Database connection lost');
this.logger?.critical('Out of memory');
this.logger?.error('Failed to process payment', { orderId: '123' });
this.logger?.warning('Rate limit approaching');
this.logger?.notice('New client registered');
this.logger?.info('Order processed');
this.logger?.debug('Cache hit for key xyz', { key: 'xyz' });
```

The `?.` operator ensures the code works even without a logger (e.g., in tests).

---

## Trace ID / Request correlation

Every request gets a unique `trace_id` (UUID v4) for log correlation.

- **Auto-generated:** If no `X-Request-ID` header is present
- **Propagated:** If the client sends `X-Request-ID`, that value is used
- **Response header:** `X-Request-ID` is set in every response

```bash
# Client provides trace ID
curl -X POST http://localhost:8080/api/users/create \
  -H "Content-Type: application/json" \
  -H "X-Request-ID: my-correlation-id" \
  -d '{"email": "user@example.com"}'

# Response header: X-Request-ID: my-correlation-id
```

All logs within the same request share the same `trace_id`, enabling end-to-end tracing in Grafana/Loki.

---

## JSON log format

Each log is a single JSON line written to stdout:

| Field         | Type     | Always present        | Description                           |
| ------------- | -------- | --------------------- | ------------------------------------- |
| `ts`          | `number` | Yes                   | Unix timestamp (seconds.milliseconds) |
| `level`       | `string` | Yes                   | Level name (lowercase)                |
| `severity`    | `number` | Yes                   | RFC 5424 numeric value                |
| `msg`         | `string` | Yes                   | Log message                           |
| `service`     | `string` | Yes                   | Service name (from `title`)           |
| `trace_id`    | `string` | Yes                   | Request correlation ID                |
| `method`      | `string` | Request/Response logs | HTTP method                           |
| `route`       | `string` | Request/Response logs | Request path                          |
| `status`      | `number` | Response logs         | HTTP status code                      |
| `duration_ms` | `number` | Response logs         | Request duration in ms                |
| `fields`      | `object` | When provided         | Custom structured data                |

---

## Excluded routes

These routes are excluded from logging by default (no request/response logs emitted):

- `/health`
- `/metrics`
- `/docs`
- `/docs/`

---

## Status code → log level mapping

Response logs automatically use the appropriate level:

| Status range | Level     |
| ------------ | --------- |
| 1xx          | `notice`  |
| 2xx          | `info`    |
| 3xx          | `info`    |
| 4xx          | `warning` |
| 5xx          | `error`   |

---

## Testing with logger

Use `useCaseTestHandler` with an optional logger:

```ts
import { useCaseTestHandler, RequestScopedLogger, LogLevel } from 'modular_api';

const lines: string[] = [];
const logger = new RequestScopedLogger({
  traceId: 'test-trace',
  serviceName: 'test',
  logLevel: LogLevel.debug,
  writeFn: (line) => lines.push(line),
});

const response = await useCaseTestHandler(MyUseCase.fromJson, { name: 'World' }, { logger });

expect(response.statusCode).toBe(200);
// Verify logs were emitted
expect(lines.some((l) => l.includes('test-trace'))).toBe(true);
```

---

## Grafana / Loki configuration

Since logs are single-line JSON to stdout, any container orchestrator (Docker, Kubernetes) can forward them to Loki. Use this Loki query to filter by service and trace:

```logql
{job="my-service"} | json | service="My Service" | trace_id="a1b2c3d4-..."
```

---

## Configuration reference

| Parameter  | Type       | Default         | Description                     |
| ---------- | ---------- | --------------- | ------------------------------- |
| `logLevel` | `LogLevel` | `LogLevel.info` | Minimum severity to emit        |
| `title`    | `string`   | `'Modular API'` | Used as `service` field in logs |
