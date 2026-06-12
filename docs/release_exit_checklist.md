# Release Exit Checklist

Status date: 2026-06-06
Goal: PR readiness for complementary package release train

## A. Workflow Coverage

- [x] 11 missing workflows added for complementary packages
- [x] Existing core workflows kept intact
- [x] Tag-to-version validation implemented in each new workflow
- [x] Secret checks implemented (`NPM_TOKEN`, `PYPI_TOKEN`, `DART_PUB_CREDENTIALS_JSON`)

## B. Build/Test Validation

- [x] Dart complementary packages validated in this session
- [x] TypeScript complementary packages validated in fully clean deterministic shell
- [x] Python complementary packages validated with deterministic `python -m pytest` run

Reference report: docs/release_validation_matrix.md

## C. Publish Preconditions

- [x] TypeScript package metadata set publishable where required (`private=false`)
- [x] Dart package metadata set publishable where required (`publish_to` removed or set for pub.dev)
- [x] Python workflows use `python -m pytest` to avoid PATH-dependent failures
- [x] Workflow checks intentionally fail fast when metadata is not publishable
- [ ] Release order executed so dependency-linked packages publish after their prerequisites

## D. GraphQL Plugin Completion Gate

Current objective answer:
- Implementation exists across Dart/TypeScript/Python with unit, contract, and integration tests.
- Development and validation gates for this PR are green. Final 100% release completion depends on successful post-merge publish runs.

## E. Final Go/No-Go

Current state: GO-FOR-MERGE (release execution pending)

Post-merge execution plan:
1. Publish in dependency-safe order by language (`rest_client` before `graphql_client`).
2. Verify successful workflow runs and registry versions.
3. Update this checklist to GO-FOR-RELEASE once publish verification is complete.

## F. Coordinated Release Mechanism (since 0.5.0)

- The whole ecosystem is released with a SINGLE tag `v<version>` that triggers `.github/workflows/release.yml` (validate -> wave 1 -> wave 2 -> verify, idempotent per package).
- Do NOT push per-package tags in bulk: GitHub suppresses tag push events when more than 3 tags are pushed at once, so multi-tag pushes silently publish nothing.
- The per-package `publish-*.yml` workflows are `workflow_dispatch`-only and exist for individual republication.
