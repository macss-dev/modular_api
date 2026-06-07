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
- [ ] TypeScript complementary packages validated in fully clean deterministic shell (2/4 still marked partial)
- [ ] Python complementary packages validated with deterministic `python -m pytest` run (4/4 still marked partial)

Reference report: docs/release_validation_matrix.md

## C. Publish Preconditions

- [ ] TypeScript package metadata set publishable where required (`private=false`)
- [ ] Dart package metadata set publishable where required (`publish_to` removed or set for pub.dev)
- [x] Workflow checks intentionally fail fast when metadata is not publishable

## D. GraphQL Plugin Completion Gate

Current objective answer:
- Implementation exists across Dart/TypeScript/Python with unit, contract, and integration tests.
- Not yet accepted as 100% release-complete under strict gate until Section B deterministic matrix is fully green and publish preconditions in Section C are resolved.

## E. Final Go/No-Go

Current state: NO-GO (pending B and C)

To switch to GO:
1. Execute clean deterministic rerun for partial matrix entries.
2. Flip package metadata to publishable values for targeted packages.
3. Re-run matrix and update docs/release_validation_matrix.md with all PASS.
