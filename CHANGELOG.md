# Changelog

All notable changes to rules_lean. The format is loosely
[Keep a Changelog](https://keepachangelog.com/) — version headers
mirror the published bazel-registry entries.

## 0.3.0 — RulesLean Lean library + lake_imports_manifest

- Promote `v0.3.0-rc1` and pin to Lean `v4.30.0-rc2` for cslib compatibility.
- Add `RulesLean.Internal.Closure` (transitive olean closure computed from the
  Lake manifest) and `RulesLean.Internal.AxiomDeps` (`declaredAxioms` +
  `isAxiom`, Internal v0.1).
- CI: add a `ruleslean_library` matrix job so the in-tree Lean library is
  built + tested on every PR.
- Untrack `.vscode/` and notebook scratch artifacts; tighten `.gitignore`.

### 0.3.0-rc1 — RulesLean scaffold + manifest tooling

- Introduce the `RulesLean` Lean library under `lean/lib/` (Olean + Lake) and
  wire it through Bazel.
- Add the `lake_imports_manifest` target: workspace API,
  `exportedConstants` + `containsConstant`, and the `Internal` namespace
  convention with `namespacePackageIndex`.
- Add `tools/reservoir_manifest.py` — a stdlib-only Reservoir index fetcher.
- Update the install snippet to point at `fastverk/bazel-registry`.

## 0.2.2 — Un-dev bazel_skylib

- Promote `bazel_skylib` out of `dev_dependency` so downstream consumers can
  actually `load()` `lean/BUILD.bazel` without re-declaring it.

## 0.2.1 — README, license, CI, smoke test

- Bump module version to 0.2.1.
- Add `README.md`, MIT `LICENSE`, and the PR-gate CI workflow.
- Add a Batteries-only `lake_workspace` smoke test.
- Apply buildifier formatting fixes across the tree.

## 0.2.0 — Generalized Lake integration + stardoc

- Generalize the Lake integration so `lake_workspace` works for arbitrary
  Lake projects instead of being hard-coded to a single layout.
- Add stardoc generation for the public rules.

## 0.1.0 — Initial release

- First public cut of `rules_lean`: `lean_test`, `lean_emit`,
  `lean_prebuilt_library`, `lean_toolchain`, and the initial `lake_workspace`
  repository rule + `lake` module extension reusing Mathlib's Reservoir
  cache.
