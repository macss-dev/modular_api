# Deployment Guide

How deployed modular_api services declare their `basePath` and how deployment
tooling consumes it.

## basePath as the single source of truth

Every modular_api service mounts all of its endpoints — modules, plugin routes,
and operational endpoints — under one `basePath`. Deployment tooling (health
probes, reverse proxies, publish pipelines) needs that value, so each SDK defines
a conventional place to declare it in the package manifest:

| SDK | Manifest | Convention |
|---|---|---|
| TypeScript | `package.json` | `"modularApi": { "basePath": "/api/v1" }` |
| Dart | `pubspec.yaml` | `modular_api:` section with `basePath: /api/v1` |
| Python | `pyproject.toml` | `[tool.modular_api]` table with `base_path = "/api/v1"` |

### TypeScript

```jsonc
// package.json
{
  "name": "my-service",
  "version": "1.4.0",
  "modularApi": {
    "basePath": "/api/v1"
  }
}
```

### Dart

```yaml
# pubspec.yaml
name: my_service
version: 1.4.0

modular_api:
  basePath: /api/v1
```

### Python

```toml
# pyproject.toml
[tool.modular_api]
base_path = "/api/v1"
```

Keep the manifest value and the value passed to the `ModularApi` constructor in
sync — ideally read the constructor value from the manifest so there is exactly
one place to change.

## Deployment healthcheck

The deployment healthcheck targets `{basePath}/health` — never `/health` at the
server root (operational endpoints moved under the basePath in the 0.4.x line;
see [operational-plugins.md](../concepts/operational-plugins.md)).

```yaml
# docker-compose example
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:8080/api/v1/health"]
  interval: 30s
  timeout: 5s
  retries: 3
```

The endpoint returns 200 for `pass`/`warn` and 503 for `fail`, so HTTP-status
probes work without parsing the body.

## Publish-NodeApi (macss-devops)

The `Publish-NodeApi` tool from the `macss-devops` module (version 3.1.0 or
later) reads the basePath convention to derive the post-deploy healthcheck URL.
Resolution precedence:

1. `package.json` -> `modularApi.basePath` (the convention above — preferred)
2. `publish.yaml` -> `api.basePath`
3. Server root (legacy fallback)

A service that declares `"modularApi": { "basePath": "/api/v1" }` is probed at
`{host}/api/v1/health` after deployment with no extra configuration.

## Checklist

- [ ] `basePath` declared in the package manifest (per-language convention above)
- [ ] `ModularApi` constructor uses the same `basePath`
- [ ] Container/orchestrator healthcheck points to `{basePath}/health`
- [ ] Prometheus scrape config points to `{basePath}/metrics` (if metrics enabled)
- [ ] `RELEASE_ID` environment variable set in the deploy environment so
      `/health` reports a meaningful `releaseId`
- [ ] macss-devops >= 3.1.0 if you rely on `Publish-NodeApi` reading the convention
