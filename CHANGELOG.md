# Changelog

## Unreleased

### Added

- `GgPrompts.current` draws every interactive prompt of the gg suite. Its
  default is chosen by a conditional import: `package:interact` where
  `dart:ffi` exists, and an implementation that refuses with an actionable
  message where it does not — `package:interact` reaches `dart:ffi` and
  breaks a Wasm build outright.

### Changed

- The message editor theme moved here from `gg_multi_core`, next to the
  prompts it styles.

## 1.0.1 - 2026-08-05

### Added

- Kernel, checks and publish configuration of the gg_one tool family, extracted from gg_one: `GgState`, `CommandCluster`, `DidCommand`, the check commands with `Analyzer`/`Formatter`/`Checks`, and the `.gg/gg-publish.json` handling around `PublishConfig` and `DoConfigurePublish`.
- Add the missing example to each new package

### Changed

- Split gg_one into gg_one_core, gg_one_commit, gg_one_merge and gg_one_do_publish
- Port the .gg/gg.json ignore guard from gg_one main into gg_one_core
