# gg_one_core

Kernel, checks and publish configuration of the gg_one tool family - state caching, command bases, verification steps and gg-publish.json handling.

## Settings

`GgRc` reads the settings of gg from two JSON files with the same structure:
the user's `~/.gg_rc` (`$GG_RC` names another file) and a repository's
`.gg/gg_rc`. The keys follow the command path and end with the flag they
preset:

```json
{
  "do": {
    "upgrade": { "deps": { "majorVersions": false } }
  },
  "can": {
    "commit": { "checks": false }
  }
}
```

- Precedence: a flag on the command line, then `.gg/gg_rc`, then
  `~/.gg_rc`, then the built-in default
- `do.upgrade.deps.majorVersions` and `can.commit.checks` belong to one
  repository (`GgRc.repoDefaults`, both `true`): only `.gg/gg_rc` may set
  them, a `~/.gg_rc` holding one is reported as broken
- `GgRc.load(ggLog:, repo:)` reads `~/.gg_rc` — written with
  `GgRc.builtInDefaults` when missing — and, with `repo`, `.gg/gg_rc` on top
- `GgRc.loadRepo(repo, create:)` reads `.gg/gg_rc` only; `create: true`
  writes a missing file with `GgRc.repoDefaults` and adds `!.gg/gg_rc`
  below a `.gg/*` rule of `.gitignore`, so it stays tracked
- `flag(keys)` answers a setting; invalid JSON or a non-boolean value throws
  with the file and how to fix it
- `CommandCluster(checksSetting: GgRc.commitChecks)` skips its commands and
  records success when the setting is `false`
