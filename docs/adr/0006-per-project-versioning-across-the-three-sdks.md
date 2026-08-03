# 6. Per-Project Versioning Across the Three SDKs

Date: 2026-08-02

## Status

Proposed

Amends [ADR-0002](0002-synchronized-versioning-across-sdks.md). ADR-0002 stays in force until this
one is accepted and the workflows described below exist.

## Context

ADR-0002 adopted synchronized versioning. Its decision text is specific:

> We adopt **synchronized versioning**: all three SDKs always share the same version number.

That sentence is about **the three SDKs of one package** — the incident behind it was a stale `dist/`
published as TypeScript `0.4.5`, which forced `0.4.6` for TypeScript and raised the question of whether
Dart and Python should follow. The answer, cross-language parity, was right and remains right: a
consumer comparing Dart `0.7.0` against Python `0.7.0` of the same package should get the same
behaviour. That is the D1 discipline the whole ecosystem is built on.

What came later, in a section appended for `0.5.0`, was an extension with no argument of its own:

> Synchronized versioning now covers 15 packages (5 per ecosystem)

That extension is what this ADR amends. Three pieces of evidence:

**It has already been violated.** The three cores sat at `0.6.1` while all twelve satellites sat at
`0.6.0`. Nobody decided that; it happened because a core-only fix does not justify twelve releases with
no content, and the convention gave way under the first real pressure.

**It publishes releases that say nothing.** A patch in the SQL Server read compiler has no relationship
to the GraphQL client. Under the 15-package rule it produces fourteen releases whose changelog entry is
"version bump for cross-SDK parity; no functional changes" — noise that trains a reader to skip
changelogs, in registries where nothing can be deleted.

**It does not protect the thing that actually breaks.** Preparing `0.7.0` we found three packages whose
constraints on their siblings were still `^0.6.0`, which resolves to `>=0.6.0 <0.7.0`. Publishing all
fifteen at one version would have shipped `modular_api_sqlserver 0.7.0` requiring a `0.6.x` core.
Synchronizing the `version:` fields does not synchronize the constraints between them, so the rule
delivered the appearance of coherence and not the substance.

A fourth consideration is mechanical. `release.yml` carries this warning:

> Do NOT push per-package tags (`<eco>-<package>-v*`): GitHub suppresses tag push events when more
> than 3 tags are pushed at once, so multi-tag pushes silently publish nothing.

A single tag was the workaround for a limitation of tags, not a versioning decision.

## Decision

**Parity is per project across the three languages, not across all projects.**

Each of the five projects versions independently. Within a project, the Dart, TypeScript and Python
packages always carry the same version, and none of the three is published unless all three agree on
it. `docs-ui` remains outside, on its own `0.1.x` line, as it already is.

The publish trigger stops being a tag and becomes **a version change in the manifests**. On a push to
the default branch, for each project: if its three manifests declare the same version and that version
is absent from all three registries, publish the three together; otherwise do nothing.

Two properties of that trigger matter, and they are the reason it is not "publish when the folder
changes":

- **A path change is not a release decision.** A README typo, a comment, a test-only commit would all
  trigger a publish of a version identical in behaviour to the previous one — or an attempt to publish
  a version that already exists.
- **Parity becomes enforced instead of conventional.** The job refuses to publish when Dart, TypeScript
  and Python disagree. Today parity is a convention plus a validate job that checks fifteen manifests
  against a tag; nothing stops a single language from being published alone.

Publication stays idempotent — a version already present in a registry is skipped with a notice — so a
partial failure can be re-run.

## Consequences

- **A project's release says something.** Its changelog contains only changes to it.
- **Cross-language parity is checked by a machine**, at the moment of publishing, per project.
- **Inter-project dependencies need explicit ordering.** The graph is small and must stay small:
  `modular_api_sqlserver` → `modular_api`, and `modular_api_graphql_client` →
  `modular_api_rest_client` (Dart and TypeScript; Python has none). The dependency's project publishes
  first, and the dependent's constraint must admit the version being published — the defect found while
  preparing `0.7.0`. A guard belongs in the workflow: refuse to publish a package whose constraint on a
  sibling excludes that sibling's current version.
- **Versions across projects will diverge, visibly.** `modular_api 0.9.x` alongside
  `modular_api_sqlserver 0.7.x` is the correct state, not drift. This is the consequence to accept
  deliberately: ADR-0002's "consumers can assume version alignment" stops holding **across** projects
  and keeps holding **within** one.
- **The `0.7.0` baseline is clean.** All fifteen packages are published at `0.7.0`, so the first
  per-project release starts from one line and no debt.
- **`npm ci`, not `npm install`, in the publish jobs.** The stale lockfile found while preparing
  `0.7.0` — `0.4.7` pinned against a declared `^0.6.0` — survived because the job resolves fresh. A
  lockfile that is not authoritative at publish time is a lockfile that documents nothing.
- **`release.yml` is retired**, and the five `publish-*-<project>.yml` per-language workflows are
  replaced by five per-project workflows, each publishing three packages.

## Migration

Tracked in [issue #32](https://github.com/ccisnedev/modular_api/issues/32). Recorded here so the
order is not rediscovered:

1. Publish `0.7.0` for all fifteen with the existing machinery. All fifteen manifests already declare
   it, so the tag is coherent; and new publish automation should not make its debut on a release that
   an investigation depends on, into registries that cannot be undone.
2. Write the five per-project workflows and prove each on a no-op patch release of a leaf project —
   one with no siblings depending on it.
3. Retire `release.yml` and mark ADR-0002 superseded by this one.
