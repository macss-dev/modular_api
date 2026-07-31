# Open-Source Contributions

Gaps we found in upstream projects while building modular_api, and what we intend to do about each.

This file is versioned so the state survives conversations and can be updated as things happen. Every
entry records **how the gap was found**, **where it should land**, **status**, and **what we are waiting
on**. Nothing here is a commitment to upstream maintainers — it is our own tracking.

**The rule we hold ourselves to: we only offer what we already run in production.** A contribution
backed by "this ships in a real service" is worth more than a patch backed by an opinion, and it costs
the maintainer less to trust. That is why these are opened after a release, not during development.

**And we open an issue before a PR.** Describe the gap, cite the production use, propose a shape, and
let the maintainer say where it belongs. A surprise PR against someone else's architecture is a favour
that costs them a review.

Status values: `identified` → `asked` → `accepted` / `declined` → `submitted` → `merged` / `abandoned`.

---

## 1. W3C `traceparent` propagator in the OpenTelemetry API package

| | |
|---|---|
| **Target** | [`dartastic_opentelemetry_api`](https://pub.dev/packages/dartastic_opentelemetry_api) |
| **Status** | `identified` (2026-07-30) |
| **Confidence** | Highest of the four |
| **Blocked on** | Nothing. Ready to ask once 0.7.0 ships. |

**How we found it.** ADR-0005 (amended) A1/A2 put the OpenTelemetry **API** in modular_api's core and
keep the SDK out. Opening Stage 3 of the tracing work, we needed a W3C `traceparent` propagator and
found it is not in the API package — it lives in `dartastic_opentelemetry`, the SDK. So a Dart library
that wants to propagate context without depending on an SDK cannot, and we had to write our own
(runbook D26).

**Why it belongs there.** The OpenTelemetry specification places propagators at the **API** layer, and
the official Python package proves an API-level implementation is feasible:
`opentelemetry.trace.propagation.tracecontext.TraceContextTextMapPropagator` ships inside
`opentelemetry-api`. TypeScript is the odd one out — its W3C propagator is in `@opentelemetry/core` —
so the Dart gap is not unprecedented, but Python's placement is the one that matches the spec.

**The ask.** Move or add a W3C `TextMapPropagator` implementation to the API package, so any library can
propagate context against the API alone. Our implementation, table-driven tests included, is available
as a starting point.

**Why it matters to us specifically.** It is the difference between core depending on an API and core
depending on an SDK. Everything in ADR-0005's amendment rests on that boundary.

---

## 2. In-memory span exporter for tests

| | |
|---|---|
| **Target** | [`dartastic_opentelemetry`](https://pub.dev/packages/dartastic_opentelemetry) |
| **Status** | `identified` (2026-07-30) |
| **Confidence** | High |
| **Blocked on** | Nothing, but sequenced after #1 — one ask at a time reads better than a list. |

**How we found it.** Every stage of the tracing work asserts on captured spans (runbook G2). No
in-memory span exporter is documented in the Dart SDK, so we wrote one (runbook Stage 4).

**Why it belongs there.** Both official SDKs we bind to in the other two languages already ship one —
`@opentelemetry/sdk-trace-base` in TypeScript and `opentelemetry-sdk` in Python (runbook D22). The
precedent is unarguable, the surface is small, and it unblocks every downstream library that wants to
test its own instrumentation.

---

## 3. Google Cloud `X-Cloud-Trace-Context` propagator for Dart

| | |
|---|---|
| **Target** | **A standalone package we publish** — not dartastic |
| **Status** | `identified` (2026-07-30), package to be created as part of the 0.7.0 work |
| **Confidence** | Medium — the code is certain, the eventual home is not |
| **Blocked on** | Nothing. This one is independent of dartastic's donation timeline, which makes it the safest to act on. |

**How we found it.** Cloud Run injects `X-Cloud-Trace-Context` alongside `traceparent`, and `socia`'s
latency investigation needs the legacy header honoured to link our server span to the platform's request
span. No propagator for it exists in any Dart package — verified on pub.dev on 2026-07-30, including
`dartastic_opentelemetry`, `opentelemetry`, `comon_otel` and `purple_otel_dio`.

**Why it does not go into dartastic.** In every other ecosystem the Google propagator is a **separate
vendor package**, deliberately outside the vendor-neutral SDK:

- Python — [`opentelemetry-propagator-gcp`](https://pypi.org/project/opentelemetry-propagator-gcp/), in `GoogleCloudPlatform/opentelemetry-operations-python`
- Go — [`GoogleCloudPlatform/opentelemetry-operations-go/propagator`](https://pkg.go.dev/github.com/GoogleCloudPlatform/opentelemetry-operations-go/propagator)
- JavaScript — `@google-cloud/opentelemetry-cloud-trace-propagator`

Three ecosystems converging on the same placement is strong evidence. Sending vendor-specific code into
a neutral SDK would be the wrong shape, and a maintainer would rightly refuse it.

**Two variants, following Google's own library.** `opentelemetry-propagator-gcp` ships
`CloudTraceFormatPropagator` (reads and writes) *and* `CloudTraceOneWayPropagator` (reads only,
"intended for use with a CompositePropagator"). The one-way variant exists so a composite chain does not
emit a GCP-specific header to services that never asked for it. We adopt the same split, with read-only
as the default (runbook D27).

**Naming and stewardship.** Published as `opentelemetry_propagator_gcp`, mirroring the Python name so it
is findable by anyone arriving from another language. The README must state plainly that it is
community-maintained, that it mirrors the official Python/Go/JS packages, and that **we will hand it to
GoogleCloudPlatform or the OpenTelemetry project if either wants it**. Publishing under a generic
ecosystem name carries a duty not to squat: the verified publisher makes authorship visible, and the
offer to transfer makes the intent explicit.

---

## 4. Shelf server instrumentation

| | |
|---|---|
| **Target** | `dartastic_opentelemetry` — **but ask before writing anything** |
| **Status** | `identified` (2026-07-30) |
| **Confidence** | Lowest of the four, and not for technical reasons |
| **Blocked on** | A maintainer's answer to a question we have not yet asked. |

**How we found it.** modular_api's server-side instrumentation is built on shelf (runbook Stages 5, 8,
9). The open-source Dart SDK ships no HTTP server instrumentation, so ours is entirely ours.

**Why the confidence is low.** The commercial Dartastic.io offering advertises shelf among "over 50 OSS
OpenTelemetry integration libraries for Dart and Flutter", while the open-source SDK ships none.
Contributing free shelf instrumentation may cut across the maintainer's business model.

**That is their call, not ours.** Asking costs one issue comment. If the answer is no, the
instrumentation stays inside modular_api where it already works, and nothing is lost. What would be
wrong is writing it, opening a PR, and putting a maintainer in the position of declining work already
done — or accepting work that undercuts their livelihood.

**The question to ask, verbatim enough to reuse:** *"We maintain a Dart API framework with
shelf-based OpenTelemetry instrumentation running in production. Would an OSS shelf instrumentation
package be welcome in this project, or does it overlap with the Dartastic.io integrations in a way that
makes it unwelcome? Happy either way — we would rather ask than assume."*

---

## 5. Offering maintenance, not only code

| | |
|---|---|
| **Target** | [`open-telemetry/community#2718`](https://github.com/open-telemetry/community/issues/2718) — the Dart API/SDK donation proposal |
| **Status** | `identified` (2026-07-30) |
| **Confidence** | Depends entirely on capacity we have not yet committed |

**Context.** OpenTelemetry published a call for contributors for Dart and Flutter. A project proposal to
bootstrap the SIG and the donation proposal for the Dart API and SDK are both under review, with six
maintainers across four sponsoring organizations committed. The project asks contributors to "maintain
the codebase, participate in regular SIG meetings, and generally help drive the SDK forward".

**Why it is worth considering.** modular_api pins `dartastic_opentelemetry_api` in core and anticipates
a rename when the donation completes (ADR-0005 A6). Having a voice in that dependency is worth more than
any single patch: breaking changes arrive as things we help shape rather than things we absorb.

**What it actually commits us to — the distinction that matters.** Contributing patches and becoming a
maintainer are **two different commitments**, and #1 through #4 need only the first:

- **Contributing** is bounded. A PR, a review cycle, done. No standing obligation.
- **Maintaining** is ongoing and public: issue triage, reviewing other people's work, recurring SIG
  meetings, and — if the donation completes — CNCF/OpenTelemetry governance, which means a CLA and more
  process than a personal repository.
- The real risk is **volunteering and then going quiet**. A maintainer who disappears is worse for a
  project than someone who never signed up, because others planned around them.

**Recommendation.** Do #1 through #4 as a contributor first. Decide on maintainership afterwards, with
evidence about how much time the contributions actually took, and only if it can be sustained. The
offer is more credible after a couple of merged patches anyway.

---

## Log

| Date | Entry | Change |
|---|---|---|
| 2026-07-30 | all | Created from the ADR-0005 tracing work. Four gaps identified, one repointed from dartastic to a standalone package after checking ecosystem convention. |
