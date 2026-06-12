# Request Lifecycle

This page documents the exact order of the HTTP pipeline assembled by
`ModularApi.serve()`. The order below is verified against the TypeScript source
(`code/ts/modular_api/src/core/modular_api.ts`, method `serve`); Dart and Python
mirror the same slot semantics on Shelf and Starlette.

## Pipeline order

```
            incoming request
                  |
                  v
 +--------------------------------------+
 | 1. logging middleware                |  trace_id (X-Request-ID), request /
 |                                      |  response JSON logs
 +--------------------------------------+
                  |
                  v
 +--------------------------------------+
 | 2. express.json + body parser error  |  JSON body parsing; SyntaxError
 |    handler                           |  responses carry the trace_id
 +--------------------------------------+
                  |
                  v
 +--------------------------------------+
 | 3. preRouting plugin middlewares     |  metrics middleware lives here
 |                                      |  (slot preRouting, order 0)
 +--------------------------------------+
                  |
                  v
 +--------------------------------------+
 | 4. user middlewares via api.use()    |  applied in registration order
 |                                      |  (includes any Router you mount here)
 +--------------------------------------+
                  |
                  v
 +--------------------------------------+
 | 5. preHandler plugin middlewares     |
 +--------------------------------------+
                  |
                  v
 +--------------------------------------+
 | 6. postHandler plugin middlewares    |  mounted after preHandler; "post"
 |                                      |  behavior is implemented by hooking
 |                                      |  the response (e.g. res.on('finish'))
 +--------------------------------------+
                  |
                  v
 +--------------------------------------+
 | 7. root router                       |
 |    a. module use case routes         |  registered at api.module() time
 |    b. plugin routes (applyRoutes)    |  appended during serve()
 +--------------------------------------+
                  |
                  v
 +--------------------------------------+
 | 8. unhandled request handler         |  structured JSON 404 / error
 +--------------------------------------+
```

Notes on step 7: plugin routes are applied onto the same root router that already
holds the module routes (`pluginHost.applyRoutes(rootRouter)` runs during `serve()`,
after every `api.module()` call has mounted its sub-router). Within the router,
module use case routes therefore match before plugin routes. Path collisions cannot
occur silently: duplicate plugin `(method, path)` pairs are rejected at startup.

## Middleware slots

Plugins register middleware into one of three slots
(`host.registerMiddleware({ slot, order, handler })`):

| Slot | Position | Typical use |
|---|---|---|
| `preRouting` | Before user middlewares (step 3) | Global guards, metrics, rate limiting |
| `preHandler` | After user middlewares (step 5) | Auth for use case/plugin routes |
| `postHandler` | After preHandler (step 6) | Response post-processing via hooks |

Ordering inside a slot is deterministic: lower `order` runs first; plugin setup
order breaks ties (user plugins set up before official plugins, so a user-plugin
preRouting middleware with `order: 0` runs before the official metrics middleware).

Plugin middlewares are **global** — they see every request. There is no per-route
middleware registration; a middleware that should only apply to some routes must
filter on `req.path` / `req.method` itself. See [plugin-host.md](plugin-host.md).

## Security warning: preHandler does NOT protect api.use() routers

A guard (auth check, API key validation) registered in the `preHandler` slot runs
at step 5 — **after** the user middlewares of step 4. Anything you mounted with
`api.use()` (including Express routers with their own routes) has already executed
and may have already sent a response by the time the guard runs.

| You want to protect | Use |
|---|---|
| Only module use case routes and plugin routes | `preHandler` is sufficient |
| Everything, including routers mounted via `api.use()` | `preRouting` |

Rule of thumb: a security guard belongs in `preRouting` unless you have a specific
reason to let `api.use()` middlewares run unauthenticated.

## Where things attach

- The logging middleware always runs first so every later stage (including JSON
  parse errors) is correlated by `trace_id`.
- The metrics middleware is registered by the official MetricsPlugin in the
  `preRouting` slot, so it observes the full downstream pipeline. Operational
  routes (health, docs, openapi, metrics itself) are excluded from instrumentation.
- The unhandled request handler is last: requests that match no route produce a
  structured JSON response instead of the framework default.

## Related

- [Plugin host](plugin-host.md) — middleware and route registration contract
- [Operational plugins](operational-plugins.md) — health/metrics/docs endpoints
