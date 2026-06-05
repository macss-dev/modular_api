# Health Check Endpoint

`GET /health` returns an [IETF Health Check Response](https://datatracker.ietf.org/doc/html/draft-inadarei-api-health-check) with `Content-Type: application/health+json`.

---

## Default behavior

Without any registered checks the endpoint responds **200** with:

```json
{
  "status": "pass",
  "version": "0.0.0",
  "releaseId": "0.0.0-debug",
  "checks": {}
}
```

`version` and `releaseId` come from the `ModularApi` constructor:

```dart
final api = ModularApi(
  basePath: '/api/v1',
  version: '1.0.0',          // required for a meaningful health response
  releaseId: '1.0.0-abc123', // optional — see Release ID below
);
```

---

## Registering checks

Extend `HealthCheck` and call `addHealthCheck`:

```dart
import 'package:modular_api/modular_api.dart';

class DatabaseHealthCheck extends HealthCheck {
  @override
  String get name => 'database';

  @override
  Future<HealthCheckResult> check() async {
    await db.ping();
    return const HealthCheckResult(status: HealthStatus.pass);
  }
}

final api = ModularApi(basePath: '/api/v1', version: '1.0.0')
  .addHealthCheck(DatabaseHealthCheck());
```

Each `HealthCheck` must provide:

| Member | Description |
|--------|-------------|
| `name` | Key in the `checks` map (e.g. `"database"`) |
| `check()` | Async method returning a `HealthCheckResult` |
| `timeout` | Optional. Default `Duration(seconds: 5)` |

---

## HealthCheckResult

```dart
HealthCheckResult(
  status: HealthStatus.pass, // pass, warn, or fail
  output: 'Optional message',
)
```

`responseTime` is measured and injected automatically by the framework — you don't need to set it.

---

## Status aggregation

All checks run **in parallel**. The overall status uses **worst-status-wins**:

| Check results | Overall status | HTTP code |
|---------------|----------------|-----------|
| All `pass` | `pass` | 200 |
| Any `warn`, none `fail` | `warn` | 200 |
| Any `fail` | `fail` | 503 |

A check that **throws** or **exceeds its timeout** is marked `fail`.

---

## Timeout

Override the `timeout` getter to change the default 5-second deadline:

```dart
class SlowCheck extends HealthCheck {
  @override
  String get name => 'slow-dependency';

  @override
  Duration get timeout => const Duration(seconds: 10);

  @override
  Future<HealthCheckResult> check() async {
    // ...
  }
}
```

---

## Release ID

Resolved in this order:

1. Explicit `releaseId` parameter in `ModularApi` constructor.
2. Compile-time `RELEASE_ID` environment variable:
   ```bash
   dart compile exe --define=RELEASE_ID=1.0.0-abc123 bin/main.dart
   ```
3. Falls back to `$version-debug`.

---

## Example response

```json
{
  "status": "warn",
  "version": "1.0.0",
  "releaseId": "1.0.0-abc123",
  "checks": {
    "database": {
      "status": "pass",
      "responseTime": 12
    },
    "cache": {
      "status": "warn",
      "responseTime": 230,
      "output": "High latency"
    }
  }
}
```
