# Plugin Guide

This page clarifies what "reference plugin" means in modular_api.

## Short Answer

A reference plugin is **not** required to be a new published package.

For this project, a valid reference plugin is a minimal, production-shaped plugin example that:

- depends only on the public modular_api contract
- does not import internal/private SDK files
- can be mounted with `api.plugin(...)`
- shows manifest, setup, route registration, and optional validation

## Why It Exists

The goal is to prove that third-party authors can build plugins using the same public API used by official plugins.

That proof can live in documentation and examples. It does not require creating a new registry package unless we explicitly choose to distribute one.

## Current Canonical Reference

Use the cross-language Plugin Host guide as the canonical authoring reference:

- [docs/plugin_host_guide.md](docs/plugin_host_guide.md)

It already includes minimal HelloPlugin implementations for TypeScript, Dart, and Python based only on public plugin-host contracts.

## Recommended Acceptance Criteria

A "reference plugin" deliverable is complete when all points below are true:

1. TypeScript example compiles and runs with only public exports.
2. Dart example compiles and runs with only public exports.
3. Python example runs with only public exports.
4. The examples register via `api.plugin(...)` and mount under the shared `basePath`.
5. No example imports internal SDK paths.

## Optional Next Step (Only If Needed)

If we want a distributable artifact later, we can publish a separate example package. That is optional and should be treated as a packaging decision, not a plugin-host contract requirement.
