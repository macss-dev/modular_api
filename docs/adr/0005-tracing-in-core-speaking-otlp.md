# 5. Tracing Is a Core Capability, and It Speaks OTLP

Date: 2026-07-25

## Status

Accepted — **amended 2026-07-30**. Decisions 2, 3 and 9 below are superseded by A1–A6 in the
Amendment section; decisions 1, 4, 5, 6, 7, 8 and 10 stand. The superseded text is preserved
deliberately: the reasoning that led to a reversal is part of the record.

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

2. **[SUPERSEDED 2026-07-30 — see A1/A2]** **The framework does not depend on any OpenTelemetry
   library.** Core defines its own
   `ModularTracer` / `Span` contract, mirroring how `ModularLogger` is a core contract with a
   swappable sink. This survives a package rename if the Dart donation completes, keeps core
   minimal (invariant 1), and adds zero dependencies — a strictly lower bar than the GraphQL
   runtime already cleared. The accepted cost is losing free interop with third-party
   instrumentation; it is small, because every instrumentation point (request, plugin slots,
   `DbCommand`, `rest_client`) is inside this ecosystem.

3. **[SUPERSEDED 2026-07-30 — see A3]** **OTLP/HTTP with JSON encoding is the wire format. No
   protobuf, no gRPC client.** The
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

9. **[SUPERSEDED 2026-07-30 — see A4; the test-first method and the production gate survive, the
   hand-rolled OTLP goldens and three-implementation parity do not]** **Validation strategy is part
   of this decision.** Development is test-first, in this order:
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

## Amendment — 2026-07-30: depend on the OpenTelemetry API, own only the instrumentation

Decisions 2, 3 and 9 above are **superseded**. Decisions 1, 4, 5, 6, 7, 8 and 10 stand unchanged.
The original text is kept rather than rewritten, because the reasoning that led here is the point of
an ADR.

**What changed:** the maturity assessment in Q1 was wrong, and it was the load-bearing premise of
decision 2. Measured on pub.dev on 2026-07-30:

| Package | Version | Last published | Pub points | Downloads |
|---|---|---|---|---|
| `opentelemetry` (Workiva) | 0.18.11 | 4 months ago | 145 | 93.8k |
| `dartastic_opentelemetry` (SDK) | 0.9.7, `1.1.0-beta.12` | 7 days ago | 155 | 61.3k |
| `dartastic_opentelemetry_api` | 0.9.1, `1.0.0-rc.1` | 9 days ago | 160 | 63.7k |

Workiva's package marks traces *beta, production-ready*. Dartastic publishes weekly, is at release
candidate, and — decisively — **`dartastic_opentelemetry_api` supports Web**, which was the strongest
technical objection to depending on it. It carries four dependencies (`collection`, `fixnum`, `meta`,
`web`), all stable and unremarkable.

A second argument, independent of maturity, proved stronger than the symmetry argument in decision 9:
**three hand-rolled implementations that agree prove consistency, not correctness.** Same author, same
possible misreading of the specification, three times, validating itself. Whereas an official SDK in
TypeScript plus an official SDK in Python plus a hand-rolled Dart implementation, compared against
one another, makes the two official ones an **oracle** for the third. That is stronger validation and
less work. Once the oracle argument is accepted for TS and Python, the case for hand-rolling Dart
collapses too: the SDK exists, it is web-safe, and it is on its way to becoming official.

**Amended decisions:**

- **A1 — Core depends on `dartastic_opentelemetry_api`, and on nothing else from OpenTelemetry.** The
  API package is the layer the specification designed for exactly this: it is no-op when no SDK is
  installed, so a consumer who never enables tracing pays nothing. The framework instruments against
  the API.
- **A2 — Core never depends on an OpenTelemetry SDK or exporter.** The application supplies a
  configured `TracerProvider` through `TracingOptions`; `dartastic_opentelemetry`, `grpc` and
  `protobuf` live in the application's dependency tree, never in the framework's. This is ADR-0004's
  shape exactly — the framework ships the contract, the consumer supplies the adapter — and it keeps
  core web-safe. The dependency guard test is not deleted, it is **inverted**: assert the API is
  present and the SDK, `grpc` and `protobuf` are absent.
- **A3 — The framework no longer owns the wire format.** No OTLP serializer, no span model, no id
  generation, no sampler, no span processor, no exporter. The SDK provides all of it, including
  OTLP/gRPC and OTLP/HTTP-protobuf exporters. The OTLP/JSON reasoning in decision 3 is moot: the
  application picks an exporter, and HTTP+protobuf is a `MUST` for receivers, so the Collector
  requirement that JSON would have imposed disappears. What survives from decision 3 is the
  principle, not the mechanism: the framework carries no vendor exporter and no cloud credentials.
- **A4 — TypeScript and Python bind to their official OpenTelemetry SDKs.** Hand-rolling in three
  languages is abandoned. Parity (G6) is redefined: it compares **the spans our instrumentation
  produces** — names, kinds, attributes, hierarchy — not a wire payload we serialize. Spec-derived
  OTLP goldens (G2) are dropped along with the serializer.
- **A5 — What remains genuinely ours** is the part no library can provide: the propagation
  *precedence policy*, a `X-Cloud-Trace-Context` propagator (verified absent from dartastic), the
  instrumentation points (server span, per-middleware spans, `DbCommand`, `rest_client`), the plugin
  lifecycle, and log↔trace correlation. This is a materially smaller surface than the original plan.
- **A6 — Pre-1.0 dependency risk is accepted and mitigated by participation.** `dartastic_opentelemetry_api`
  is at `1.0.0-rc.1` and under donation review; if it becomes an official OpenTelemetry artifact it
  will likely be renamed, forcing one migration. We accept that, pin a version range, and
  **contribute upstream** — the project published a call for contributors, and three gaps we need are
  already identified as contribution candidates: a Google Cloud propagator, server-side
  instrumentation for shelf, and an in-memory span exporter for tests. Having a voice in a
  specification we consume is worth more than the insulation an in-house contract would buy.

- **A7 — There is no tracing plugin, and decision 4's "official plugin owns configuration, sampler,
  span processor, exporter and lifecycle" describes nothing that exists.** Added 2026-07-30. Each of
  those five responsibilities was reassigned by a later decision: A2 moved the sampler, processor and
  exporter to the application; decision 4's own correction made the span host-owned, so no middleware
  is registered; the shutdown became a callback the application supplies (runbook D8 as revised,
  because the OpenTelemetry API exposes no provider shutdown in TypeScript or Python); and the
  dropped-span counter was removed entirely (runbook D14).

  What remained was a plugin whose `setup()` did nothing and whose only act was forwarding one
  callback. The host reads `TracingOptions` directly instead.

  The deeper reason it never fit: every official plugin exists to add an **HTTP surface**, and the
  plugin contract's four powers are route registration, middleware registration, boot validation and
  shutdown. Tracing has no endpoint; it *cannot* register middleware, because the span must sit
  outside every plugin slot; it has nothing to validate; and its shutdown is one line in the host.
  **Invariant 2 constrains how official plugins are built, not what must be a plugin.**

  A finding worth carrying forward: the plugin contract cannot express "outermost middleware", so no
  third party can build cross-cutting instrumentation today. That is a candidate for a plugin-host
  ADR, and it surfaced only because tracing was attempted as a plugin.

**What this costs, stated plainly:** invariant 1 ("the core stays minimal") absorbs one direct and
four transitive dependencies where the original plan added none. That is the price of correctness by
oracle instead of correctness by self-agreement, and of not maintaining a specification
implementation across three languages for years.

## Rejected alternatives

- **Depend on `dartastic_opentelemetry_api` in core.** Originally rejected on rename risk and on the
  existence of in-house contracts for logging and metrics. **This rejection was reversed on
  2026-07-30 — see the Amendment above.** The stated reason to revisit ("if and when the Dart API
  becomes an official OpenTelemetry artifact") turned out to be the wrong trigger: what mattered was
  that the package is already web-safe and at release candidate, and that hand-rolling in three
  languages produces self-validating rather than validated code.
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

> The consequences below are stated as amended. Where the original decisions 2, 3 or 9 shaped them,
> the text reflects A1–A6, not the superseded version.

- **Traces join logs and metrics**, completing the observability surface. Core takes one new
  dependency — the OpenTelemetry **API** — and never an SDK or exporter (A1, A2).
- **A coordinated multi-package release.** The contract lives in core, but instrumentation touches
  `modular_api_postgres` (span around `DbCommand` execution) and `modular_api_rest_client`
  (client span plus `traceparent` injection). Because the database packages are contracts-only
  (ADR-0004), instrumenting the contract means every adapter is instrumented for free — a direct
  dividend of that decision.
- **Three SDKs, three bindings to official APIs** (A4). Parity compares the spans our
  instrumentation produces, not a wire payload (G6 as redefined).
- **The deployment owns the destination.** For `socia`, that means a Collector sidecar on Cloud
  Run, in `code/infra`, alongside the existing Prometheus/GMP wiring. Two prerequisites will
  silently invalidate the final gate if missed: **Trace storage is currently disabled in the
  `sociacacsi` project**, and the first deployment should sample at 100% — the daily burst is the
  event to capture, and partial sampling would likely miss it.
- **The home-grown `trace_id` is superseded, not removed.** `X-Request-ID` remains the last
  propagation fallback and its original value is preserved as a separate log field, but the
  `trace_id` field itself changes shape to the 32-hex W3C id. That is a log-format change, and the
  runbook treats it as the highest-blast-radius item in the work.
- **A maintenance liability is accepted knowingly, and it is a different one than first planned.**
  Not a wire format across three languages, but a pre-1.0 dependency under donation review that will
  probably be renamed once (A6). Mitigated by a pinned range and by contributing upstream.
- **gRPC now has a design constraint to satisfy, not a dependency to wait for**: decision 5 means
  the transport arrives as an adapter.
