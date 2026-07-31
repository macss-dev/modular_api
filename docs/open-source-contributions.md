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
is findable by anyone arriving from another language. Starting at **0.0.1**, its own version line. The
README must state plainly that it is community-maintained, that it mirrors the official Python/Go/JS
packages, and that **we will hand it to GoogleCloudPlatform or the OpenTelemetry project if either wants
it**. Publishing under a generic ecosystem name carries a duty not to squat: the verified publisher makes
authorship visible, and the offer to transfer makes the intent explicit.

**It lives in its own repository, not in `modular_api/code/`.** Decided 2026-07-30. Four reasons, and the
first is decisive given that donation is the stated goal:

1. **Donation is a one-click operation from its own repo.** GitHub's *Transfer ownership* moves the repo,
   its issues, its stars and its history in a single action. Extracting a subdirectory from another
   project's repository means `git filter-repo` surgery and hands the recipient a history entangled with
   an unrelated framework. If we intend to give this away, we should not build it somewhere that makes
   giving it away a project.
2. **modular_api does not depend on it, so there is no coupling to pay for.** After the architectural
   correction, core's default propagator chain is W3C only and the Cloud Trace propagator is supplied by
   the *application*. `socia` depends on this package; the framework does not. Nothing about keeping them
   together would have been convenient anyway.
3. **Provenance is auditable.** If OpenTelemetry accepts a donation they need clear licence and
   authorship history. A repository containing only this package is trivial to audit; a monorepo's
   history is not.
4. **It follows the structure that already exists.** `macss/` is a set of sibling independent repositories
   — `modular_api`, `cli_router`, `service_client` and the rest are each their own repo. A new sibling is
   the existing pattern, not a new one.

**Location:** `macss/opentelemetry_propagator_gcp`, sibling to `modular_api`. During development `socia`
points at it with a `path:` override, the same mechanism Stage 14 of the tracing runbook already uses for
the framework itself; the override is removed when the package is published.

**Sequencing.** It must exist before the runbook's Stage 3, because Stage 3 composes the default
propagator chain and needs to know what that chain does *not* include. It must be published before or
alongside `0.7.0`, so `socia`'s dogfood runs against a published version rather than a local path.

---

## 4. Shelf server instrumentation

| | |
|---|---|
| **Target** | `dartastic_opentelemetry` — **but ask before writing anything** |
| **Status** | `asked` — pending an answer |
| **Confidence** | Lowest of the four, and not for technical reasons |
| **Asked on** | 2026-07-30 |
| **Next review** | **2026-08-30**, then quarterly. No answer is itself an answer; see below. |

**How we found it.** modular_api's server-side instrumentation is built on shelf (runbook Stages 5, 8,
9). The open-source Dart SDK ships no HTTP server instrumentation, so ours is entirely ours.

**Why the confidence is low.** The commercial Dartastic.io offering advertises shelf among "over 50 OSS
OpenTelemetry integration libraries for Dart and Flutter", while the open-source SDK ships none.
Contributing free shelf instrumentation may cut across the maintainer's business model.

**That is their call, not ours.** Asking costs one issue comment. If the answer is no, the
instrumentation stays inside modular_api where it already works, and nothing is lost. What would be
wrong is writing it, opening a PR, and putting a maintainer in the position of declining work already
done — or accepting work that undercuts their livelihood.

**A question is not a contribution.** The "only offer what runs in production" rule governs *code*. Asking
costs a maintainer thirty seconds and the answer shapes whether we write anything at all, so it goes out
now rather than after `0.7.0`.

**The question as sent:**

> We maintain modular_api, a use-case-centric API framework for Dart, and we have just built
> OpenTelemetry instrumentation for it on top of `dartastic_opentelemetry_api` — server spans over shelf,
> per-middleware spans, client spans, and database spans at the contract level. It runs in production in a
> financial cooperative's backend.
>
> Two questions, and we would rather ask than assume:
>
> 1. Would an open-source **shelf server instrumentation** package be welcome in this project? We noticed
>    Dartastic.io advertises shelf among its integrations while the OSS SDK ships none, and we do not want
>    to contribute something that cuts across how you fund the work. A "no thanks" is a perfectly good
>    answer and we will simply keep it inside our framework.
> 2. Separately and much smaller: would you take a **W3C `traceparent` propagator in the API package**?
>    The specification places propagators at the API layer and the official Python package ships one in
>    `opentelemetry-api`, but in Dart it is only in the SDK — so a library that instruments against the
>    API alone cannot propagate context. We wrote one and would rather upstream it than keep a private
>    copy. Same for an **in-memory span exporter** for tests, which both the TS and Python SDKs provide.
>
> Thanks for the work on this — the API package supporting web is what made it possible for us to depend
> on it in a framework core.

**Reading the silence.** Open-source maintainers owe nobody a reply, and this project is mid-donation with
limited capacity. If there is no answer by the second review, treat it as an implicit "not now": keep the
shelf instrumentation private, and consider opening #1 and #2 as small, self-contained PRs anyway, since
those are additive to the API package and cheap to decline.

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

## Decisions

Kept separately from the log so the reasoning is findable, not buried in a diff.

- **2026-07-30 — Contribute first, decide on maintainership later.** Entries #1 to #4 need only the
  contributor commitment, which is bounded: a PR, a review cycle, done. Maintainership is ongoing and
  public, and the failure mode that actually damages a project is volunteering and then going quiet.
  So: do the contributions, measure how much time they really take, and revisit maintainership with
  evidence rather than enthusiasm. The offer is also more credible after a couple of merged patches.
  **Revisit:** once at least two of #1–#4 have been resolved either way.
- **2026-07-30 — The Cloud Trace propagator gets its own repository** (`macss/opentelemetry_propagator_gcp`),
  not a directory inside `modular_api`. Donation is the stated goal, and from its own repo that is a
  single GitHub *Transfer ownership*; from a subdirectory it is history surgery. Full reasoning in entry #3.
- **2026-07-30 — Questions go out immediately; code waits for production.** The "only offer what runs in
  production" rule governs contributions, not conversations. Asking early means the answer may already be
  in hand when we are ready to write.

## Log

| Date | Entry | Change |
|---|---|---|
| 2026-07-30 | all | Created from the ADR-0005 tracing work. Four gaps identified, one repointed from dartastic to a standalone package after checking ecosystem convention. |
| 2026-07-30 | #3 | Decided its own repository over a directory in this one; recorded version line 0.0.1 and the sequencing constraints against the tracing runbook. |
| 2026-07-30 | #4 | Question drafted and sent, covering shelf instrumentation plus the two smaller API-package asks. Review 2026-08-30, then quarterly. |
| 2026-07-30 | #5 | Recorded the contribute-first decision and when to revisit it. |
