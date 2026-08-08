# Changelog

## Unreleased

### Changed

- A project that ships no TypeScript sources — a hybrid whose
`package.json` exists to publish a payload to npm, with no
`tsconfig.json` — is no longer held to the TypeScript toolchain:
- `analyze` skips instead of falling back to `tsc --noEmit`, which
demanded a `typescript` devDependency for a compiler with nothing to
read.
- `package-json-scripts` requires only `test`, not `build` and `lint`.
- The publish-lifecycle script must reach `test` — via `build` where
there is one, directly otherwise. The point of the chain is that
publishing never skips the tests, not that a build step exists.
- Support npm packages without typescript

## 2.0.0 - 2026-08-08

### Changed

- Allow to pass custom options to exec of dir commands.

## 1.0.1 - 2026-08-05

### Added

- Kernel, checks and publish configuration of the gg_one tool family, extracted from gg_one: `GgState`, `CommandCluster`, `DidCommand`, the check commands with `Analyzer`/`Formatter`/`Checks`, and the `.gg/gg-publish.json` handling around `PublishConfig` and `DoConfigurePublish`.
- Add the missing example to each new package

### Changed

- Split gg_one into gg_one_core, gg_one_commit, gg_one_merge and gg_one_do_publish
- Port the .gg/gg.json ignore guard from gg_one main into gg_one_core
