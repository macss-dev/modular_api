# Changelog

## 0.7.0

- **`trace_id` changes shape when tracing is configured.** Without `tracing` it stays a dashed UUID
  v4, exactly as before; with `tracing` it becomes the 32-hex W3C trace id of the server span, which
  is what a trace backend can join on. The change is **gated on adopting tracing** so that consumers
  who do not ask for it are unaffected. Check any query, dashboard or alert that assumes the dashed
  form — see [the observability guide](../../../docs/guides/observability.md#the-trace_id-shape-change). This package does not emit that field itself; the note is here because a synchronized release moves all packages together
- add a client span per outbound call, named `{METHOD} {operationId}`, recording `server.address`,
  `server.port` and `url.path` — never the full URL, which can carry identifiers in its path or query
- **zero configuration**: nothing was added to `ServiceClientConfig`. The parent is the ambient
  server span, the tracer is the global provider, and injection goes through the global propagator,
  so enabling tracing on `ModularApi` is enough to get client spans
- trace context is injected from the **client** span, not the server span, so a downstream hop
  attaches to the call rather than to its parent
- a 4xx sets the client span to error, unlike a server span where a 4xx is the caller's mistake. Here
  it means *our* outbound call failed
- a transport failure — timeout, DNS, refused connection — ends the span with error status and **no**
  status code, because there was no response to read one from
- forward an inbound `X-Request-ID` on outbound calls, **whether or not tracing is enabled**, so log
  correlation survives a hop into a service that does not trace. Forwarded, never invented
- declares the OpenTelemetry **API** directly: this package does not depend on the framework, so it
  cannot inherit it (ADR-0005 amendment A1/A2). Still no SDK, exporter, gRPC or protobuf, enforced by
  a test

## 0.6.0

- version bump for cross-SDK parity (ADR-0002); no functional changes

## 0.5.0

- version bump for cross-SDK parity (ADR-0002); no functional changes

## 0.4.8

- replace `dart:io` `HttpClient` with `package:http` for full Flutter web (dart2js) compatibility
- `HttpServiceClient` now works on all Flutter platforms: web, mobile, desktop, and server

## 0.4.7

- bootstrap `modular_api_rest_client` for Dart
- add the first REST client slice with normalized results and failures
- add tests for happy path, decode failures, auth injection, timeout, and HTTP non-2xx normalization