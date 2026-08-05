# Changelog

## Unreleased

### Added

- Kernel, checks and publish configuration of the gg_one tool family, extracted from gg_one: `GgState`, `CommandCluster`, `DidCommand`, the check commands with `Analyzer`/`Formatter`/`Checks`, and the `.gg/gg-publish.json` handling around `PublishConfig` and `DoConfigurePublish`.

### Changed

- Split gg_one into gg_one_core, gg_one_commit, gg_one_merge and gg_one_do_publish
- Port the .gg/gg.json ignore guard from gg_one main into gg_one_core
