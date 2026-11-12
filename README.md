# gg_one_core

Kernel, checks and publish configuration of the gg_one tool family - state caching, command bases, verification steps and gg-publish.json handling.

## Per-repo settings

`RepoGgRc` holds the settings of one repository, kept in the tracked file
`.gg/gg_rc.jsonc`:

```jsonc
{
  "upgradeMajorVersions": true, // false: upgrades stay within major versions
  "enableChecks": true          // false: skippable check clusters are skipped
}
```

- `RepoGgRc.load(dir)` reads the file and creates it with its defaults when
  missing; it also adds `!.gg/gg_rc.jsonc` below a `.gg/*` rule of the root
  `.gitignore`, so the file stays tracked
- `RepoGgRc.read(dir)` reads the file without touching the disk; a missing
  file yields the defaults
- Missing keys default to `true`; a value that is no bool throws a
  `FormatException` naming the file
- `CommandCluster(skippable: true)` skips its commands and records success
  when `enableChecks` is `false`; clusters are not skippable by default
