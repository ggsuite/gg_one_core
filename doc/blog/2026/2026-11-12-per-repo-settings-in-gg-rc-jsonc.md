<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Per-repo settings in .gg/gg_rc.jsonc

## Motivation

- Some behavior of gg should be tunable per repository, not per run: a
  repository that must stay on its current major versions, or one whose
  checks are not wanted before a commit
- A command line flag has to be repeated on every call and is easily
  forgotten; a tracked file applies to everyone working on the repository
- The kernel of the tool family is the right home: every command can read
  the settings from here

## Strategy

- One small JSON-with-comments file, `.gg/gg_rc.jsonc`, next to the other
  files gg keeps in `.gg`
- Every key has a default, so a missing key or a missing file changes
  nothing
- The file is created with its defaults on first use, so users find the
  available settings without reading documentation
- The file is meant to be committed, unlike the runtime files in `.gg`
- Checks can be switched off per command cluster, opt-in by the cluster

## The RepoGgRc class

- `RepoGgRc.read(dir)` reads the settings and falls back to the defaults
  without touching the disk
- `RepoGgRc.load(dir)` reads `.gg/gg_rc.jsonc` of a repository and creates it
  from `RepoGgRc.template` when it does not exist
- Two flags, both `true` by default:
  - `upgradeMajorVersions` — whether dependency upgrades may cross major
    versions
  - `enableChecks` — whether the checks before a commit run
- Comments and trailing commas are allowed, parsed with the existing
  `Jsonc.stripComments`
- A value that is no bool, or content that is no JSON object, throws a
  `FormatException` naming the file
- `repoGgRcFile(dir)` and `repoGgRcFileName` expose the location

## Keeping the file tracked

- Repositories commonly ignore `.gg/*` and re-include `!.gg/gg.json`
- When `RepoGgRc` creates the file it adds `!.gg/gg_rc.jsonc` right below a
  `.gg/*` rule of the root `.gitignore`
- A `.gitignore` without such a rule, or one that already re-includes the
  file, is left alone

## Skippable command clusters

- `CommandCluster` got a new constructor parameter `skippable`, false by
  default
- A skippable cluster reads `enableChecks` with `RepoGgRc.read`, which never
  creates the file; when it is false the commands
  are not run, a line `<shortDescription> skipped: enableChecks is false.`
  is logged and the success state is recorded
- Recording success keeps every gate that reads the state working, so the
  work can still be committed
- Clusters that are not skippable behave exactly as before

## Open Points

- More settings can join the file; each needs a default that keeps
  today's behavior
- A `.gitignore` with an unusual `.gg` rule (wildcards, nested files) is
  not rewritten; the file then stays ignored until the rule is fixed by hand
