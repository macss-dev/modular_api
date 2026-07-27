# 5. Tracing Is a Core Capability, and It Speaks OTLP

Date: 2026-07-25

## Status

Accepted

## Context

modular_api ships two of the three pillars of observability as first-class surfaces:
request-scoped structured logging (host-owned `loggingMiddleware`) and Prometheus metrics
(`MetricsPlugin`, opt-in via `metricsEnabled`). Distributed tracing is absent. The gap is not
theoretical — it was hit head-on by the first consumer to need it.

**Evidence from production (`socia-api`, Cloud Run, GCP project `sociacacsi`):**

1. `POST /api/cuenta/get-cuenta-detalle` shows recurring bursts of 8–20 s (peak 19.8 s), all with
   `status: 200` — pure latency, no errors.
2. The request log carries only the total (`jsonPayload.duration_ms`). The time cannot be
   attributed to a stage: cold start, SQL query, connection pool, or something not yet suspected.
3. The framework emits a **home-grown** `trace_id`. `logging_middleware.dart` resolves it from
   `X-Request-ID` only, generating a UUID otherwise. Cloud Run already injects `traceparent` and
   the legacy `X-Cloud-Trace-Context`; both are ignored. A search of `lib/` for
   `logging.googleapis.com`, `traceparent`, `X-Cloud-Trace-Context` and `spanId` returns nothing.
4. Consequence: the platform's trace waterfall is empty, and log↔trace correlation is impossible
   even with Trace storage enabled, because the logs never carry the platform's trace field.

An adequate diagnosis of (1) requires spans. Nothing outside the framework can produce them: only
the host can wrap the request pipeline, the ordered plugin middleware slots, and a `DbCommand`.

Four questions had to be settled before writing code.

**Q1 — Does the framework own the implementation, or consume a library?** OpenTelemetry is
specified in three layers: an instrumentation **API**, an **SDK** (sampling, batching, export),
and the **OTLP** wire format. Only the first two are candidates for the framework; the backend
(Cloud Trace, Jaeger, Tempo) never is. A Dart implementation exists — `dartastic_opentelemetry`
plus a standalone `dartastic_opentelemetry_api` with the spec-mandated no-op behaviour — and is
in the process of being donated to OpenTelemetry (SIG bootstrap and donation proposals under
review as of 2026-07, six maintainers across four sponsoring organizations). It is a credible
dependency, but not yet an official one, and its package names may change if the donation lands.

**Q2 — Must OTLP export go over gRPC?** No. OTLP/HTTP defines a JSON encoding: port `4318`, path
`/v1/traces`, `Content-Type: application/json`, trace and span ids as case-insensitive hex
strings, 64-bit integers as decimal strings (proto3 JSON mapping), enums as integers. The
OpenTelemetry Collector's OTLP receiver accepts it and multiplexes on `Content-Type`. JSON is
`MAY` for servers, so a Collector — the recommended topology regardless — is the target. This
removes protobuf codegen, HTTP/2 and gRPC from the picture entirely.

**Q3 — Should gRPC be added first, so OTLP could ride on it?** The ordering argument inverts.
Offering gRPC as a transport for modular_api APIs means writing a gRPC **server**; exporting OTLP
over gRPC means writing a gRPC **client**. Finishing the former brings the latter no closer.
gRPC remains desirable on its own merits and is now scheduled within the 0.x series (see Roadmap),
but tracing does not depend on it.

**Q4 — A separate `modular_api_otel_sdk` package, or core?** The four official plugins are private
classes inside the core package (`lib/src/core/official_plugins.dart`:
`_HealthRuntimePlugin`, `_MetricsRuntimePlugin`, `_OpenApiRuntimePlugin`, `_DocsRuntimePlugin`),
and the GraphQL runtime plugin lives in core while pulling four dependencies (`gql`, `leto`,
`leto_schema`, `leto_shelf` — the latter three at `0.0.1-dev` pre-releases). Invariant 2 governs
the *contract*, not the packaging: an official plugin is not an extra package. Meanwhile ADR-0002
would turn one new package into three, against a roadmap direction that is explicitly reducing
the package count from 15 to 12.

## Decision

**The governing principle, stated explicitly:** the framework owns contracts and semantics, and
delegates *transports* to libraries. `shelf` for HTTP and, when gRPC lands, `grpc` and `protobuf`
are transports. OTLP is not a transport — it is a wire format plus semantics, the same class of
artifact as the Prometheus text exposition format that `metric_registry.dart` already serializes
by hand with no client library. It therefore falls on the owned side of the line.

1. **Tracing ships in the core package, as an official opt-in plugin.** No
   `modular_api_otel_sdk`, in any SDK. The analogue is `MetricsPlugin`: a plugin by contract,
   shipped in core, activated by configuration. Invariant 3 is preserved — a REST-only API stays
   valid with tracing disabled.

2. **The framework does not depend on any OpenTelemetry library.** Core defines its own
   `ModularTracer` / `Span` contract, mirroring how `ModularLogger` is a core contract with a
   swappable sink. This survives a package rename if the Dart donation completes, keeps core
   minimal (invariant 1), and adds zero dependencies — a strictly lower bar than the GraphQL
   runtime already cleared. The accepted cost is losing free interop with third-party
   instrumentation; it is small, because every instrumentation point (request, plugin slots,
   `DbCommand`, `rest_client`) is inside this ecosystem.

3. **OTLP/HTTP with JSON encoding is the wire format. No protobuf, no gRPC client.** The
   framework never talks to a vendor API and never carries cloud credentials. Reaching Cloud
   Trace, Jaeger or Tempo is the deployment's problem, solved by a Collector — an infrastructure
   artifact, not a dependency. This is ADR-0004's stance applied to telemetry: own the contract,
   never the driver.

4. **Span creation is host-owned; the plugin owns configuration and export.** This is a
   correction to the initial "tracing as a plugin" framing, forced by the pipeline order in
   `lib/src/core/modular_api.dart`: the host installs `loggingMiddleware` first (outermost), then
   `errorResponseMiddleware`, and only then plugin middleware from the ordered slots. A server
   span created inside a plugin slot would nest under logging and miss the plugin middleware
   registered before it — a waterfall with a hole at exactly the point where cold start lives.
   Therefore:
   - **Host/core:** server span lifecycle in the pipeline, adjacent to (or fused with)
     `loggingMiddleware`, which also yields log↔trace correlation for free.
   - **Official plugin:** configuration, sampler, span processor, exporter, and the
     `setup`/`validation`/`freeze`/`shutdown` lifecycle. `shutdown` is load-bearing: it is the
     only opportunity to flush queued spans before a scale-to-zero platform kills the container.

5. **The span lifecycle is transport-neutral.** Span creation must not live inside the shelf
   middleware; the shelf middleware is one *adapter* over a neutral core. When gRPC arrives it
   adds another adapter, not a refactor. This is enforced by test, not by intention (see 9).

6. **Context propagation is core, unconditionally, and standards-first.** Pure header parsing,
   zero dependencies. Resolution order: W3C `traceparent` → `X-Cloud-Trace-Context` →
   `X-Request-ID` → generate. Google recommends prioritizing `traceparent` and treating the legacy
   header as a fallback. The legacy format carries a trap worth recording: `TRACE_ID/SPAN_ID;o=OPTIONS`
   where `TRACE_ID` is 32 hex characters but `SPAN_ID` is the **decimal** representation of an
   unsigned 64-bit integer. Parsing it as hex yields a wrong parent and a silently broken
   waterfall. `modular_api_rest_client` injects `traceparent` on outbound calls, making traces
   distributed across services.

7. **`SpanExporter` is a contract; the OTLP exporter is its default implementation, behind a
   conditional import.** The pattern already exists in core for the logger
   (`log_sink_io.dart` / `log_sink_stub.dart`, introduced in 0.6.1). The OTLP exporter uses
   `dart:io` on server targets with a no-op stub on web, so core stays web-safe — protecting the
   Flutter web compatibility won in 0.4.8 and the web-safe DTO entry point in 0.6.1. Consumers may
   supply their own exporter.

8. **Semantic conventions are followed as data, not as a dependency.** Attribute names are string
   constants. Copying names from the specification is not coupling, and convention churn affects
   data, not code — which is precisely why the owned surface (OTLP wire format, W3C Trace Context)
   is the stable part.

9. **Validation strategy is part of this decision.** Development is test-first, in this order:
   propagation and id generation → span model and contract → OTLP serializer → processor and
   batching → host wiring → plugin configuration and export → Collector integration →
   `modular_api_postgres` and `modular_api_rest_client` instrumentation → production.
   - **Golden files are written from the specification, never captured from our own serializer.**
     A golden generated by the code under test enshrines its own bug and passes forever. The three
     traps to encode explicitly: hex ids (not base64), 64-bit integers as decimal strings, enums
     as integers.
   - **A real Collector runs in a container**, with a `file`/`debug` exporter, and assertions are
     made on what the Collector *received*. This turns "does our JSON look right" into "did a
     conformant receiver accept it", and is automatable in CI.
   - **Two tests protect invariants:** the no-op path must be free (plugin disabled ⇒ zero cost,
     protecting invariant 3), and at least one span must be created with no HTTP or shelf
     involvement (enforcing decision 5).
   - **The OTLP payload is the cross-SDK parity artifact** (ADR-0002): the same span in Dart,
     TypeScript and Python must produce equivalent JSON modulo ids and timestamps. Hand-rolling
     OTLP/JSON in all three SDKs — rather than binding to the official TS and Python SDKs — is
     chosen deliberately, to keep one contract and make parity tests meaningful.
   - **Production is the final gate**, as the X4 experiment was for ADR-0004. The criterion is not
     "spans appear in the backend"; it is that the 8–20 s bursts of `get-cuenta-detalle` become
     **attributable to a concrete stage** (`socia` requirement REQ-2026-07-13-002, AC-3). Spans
     that arrive but leave the time unexplained mean the gate did not pass.

10. **This amends the roadmap.** The roadmap stated that the architecture was complete and that
    every release up to 1.0.0 would be a refinement rather than a fundamentally new capability.
    That stance is revised: two foundational capabilities remain inside the 0.x line — tracing
    (this ADR) and a gRPC transport. Both are minor releases under the existing semver rules. The
    revision is recorded rather than quietly ignored, for the same reason ADR-0004 retracted the
    "first slice" phrasing: a roadmap that no longer describes the project is worse than one that
    admits a change of direction.

## Rejected alternatives

- **Depend on `dartastic_opentelemetry_api` in core.** A reasonable option, and the closest call
  here — the API package is small and no-op by default. Rejected on rename risk while the donation
  is under review, and because the equivalent contract already exists in-house for logging and
  metrics. Revisit if and when the Dart API becomes an official OpenTelemetry artifact; decision 2
  is a contract boundary, so binding it to an external API later is additive.
- **A separate `modular_api_otel_sdk` package.** Rejected per Q4: official plugins are not
  separate packages, ADR-0002 would triple the cost, and the name would promise a general-purpose
  Dart OTel SDK — an implicit commitment to specification completeness we do not intend to carry.
  The framework emits OTLP; it does not ship an OpenTelemetry SDK. Documentation must use that
  wording.
- **gRPC before tracing.** Rejected per Q3: server and client are opposite halves of the stack.
- **A protobuf/gRPC OTLP exporter.** Rejected: it is the only thing that would force protobuf
  codegen and HTTP/2 into the ecosystem, and OTLP/JSON removes the need.
- **Writing directly to a vendor trace API.** Rejected: reintroduces exactly the vendor coupling
  ADR-0004 forbids, including cloud authentication inside the framework.

## Consequences

- **Traces join logs and metrics**, completing the observability surface with a contract the
  framework owns end to end and zero new dependencies in any SDK.
- **A coordinated multi-package release.** The contract lives in core, but instrumentation touches
  `modular_api_postgres` (span around `DbCommand` execution) and `modular_api_rest_client`
  (client span plus `traceparent` injection). Because the database packages are contracts-only
  (ADR-0004), instrumenting the contract means every adapter is instrumented for free — a direct
  dividend of that decision.
- **Three SDKs, three implementations** (ADR-0002), with the OTLP payload as the parity artifact.
  The hardest SDK is Dart, which is also the one the first consumer runs.
- **The deployment owns the destination.** For `socia`, that means a Collector sidecar on Cloud
  Run, in `code/infra`, alongside the existing Prometheus/GMP wiring. Two prerequisites will
  silently invalidate the final gate if missed: **Trace storage is currently disabled in the
  `sociacacsi` project**, and the first deployment should sample at 100% — the daily burst is the
  event to capture, and partial sampling would likely miss it.
- **The home-grown `trace_id` is superseded, not removed.** `X-Request-ID` remains the last
  fallback, so existing consumers and log queries keep working.
- **A maintenance liability is accepted knowingly.** Owning a wire format across three SDKs for
  years is a real cost. It is bounded because the owned surface — OTLP encoding and W3C Trace
  Context — is stable and versioned, while the churning part (semantic conventions) is data.
- **gRPC now has a design constraint to satisfy, not a dependency to wait for**: decision 5 means
  the transport arrives as an adapter.
