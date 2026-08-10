# Changelog

## 2.3.2 - 2026-08-10

### Fixed

- Various log and color fixes across the gg command output

## 2.3.1 - 2026-08-10

### Removed

- Merge .ticket with ticket.json. Remove usage of .ticket

## 2.3.0 - 2026-08-09

### Changed

- Improve commit behavior
- Move gg commit conventions from gg_git to gg_one_core
- Answer gg did publish from git tags instead of a marker
- Record the doCommit state in system commits again

## 2.2.0 - 2026-08-09

### Changed

- Documentation: the publish flow merges into the main branch before it
uploads to the registries, and the workspace-wiring backups
(`pubspec_overrides.yaml` / `pnpm-workspace.yaml`) are restored by the
publish flow itself once the feature branch is checked out again — not by
the multi-repo flow after the merge.
- Merge in main before publishing

## 2.1.0 - 2026-08-09

### Added

- `writablePublishSteps` and `publishRegistryStep(target)` — the registry
upload is tracked **per registry** (`publish_registry_pub_dev`,
`publish_registry_npm`), so a run whose pub.dev upload succeeded before npm
failed resumes at npm alone.

### Changed

- `allowedPublishSteps` still accepts the old single `publish_registry` marker
when *reading* a leftover file, so a `--continue` across a gg upgrade resumes
instead of crashing, and `hasLegacyRegistryStep` reports it. It is never
written again, and it is deliberately not translated into the two new markers:
a hybrid could only ever have reached npm back then, so "both done" would
permanently skip pub.dev and "neither done" would re-upload to npm. The publish
flow re-asks each registry instead — a lookup it performs anyway.
- `Pana` runs for a hybrid that publishes to pub.dev. Its publish target used
to read `npm`, so pana was skipped for it entirely.
- `NpmLoggedIn` applies to every package that publishes to npm, including a
hybrid, and delegates the registry resolution to gg_lang's
`NpmRegistryResolver` — the same one the publish flow uses for its status urls.
- Allow to publish hybrid packages

## 2.0.1 - 2026-08-08

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
