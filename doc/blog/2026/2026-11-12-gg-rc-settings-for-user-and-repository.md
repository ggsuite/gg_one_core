<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# GgRc: one settings class for user and repository

## Motivation

- Some behavior of gg depends on the repository, not on the person running
  it: a repository that must stay on its current major versions, or one
  whose checks are not wanted before a commit
- A command line flag has to be repeated on every call; a tracked file
  applies to everyone working on the repository
- The user's own settings already have a format: `~/.gg_rc`, whose keys
  follow the command path. A second, differently shaped file would be one
  more thing to learn
- The kernel of the tool family is the lowest layer every command can
  reach, so the one settings class lives here

## Strategy

- One class, `GgRc`, two files with the same structure: `~/.gg_rc` and the
  repository's `.gg/gg_rc`
- Precedence: command line > `.gg/gg_rc` > `~/.gg_rc` > built-in default
- Settings that only make sense per repository can only be set there
- Reading the repository file alone never touches the home directory, so
  checks and tests stay independent of the machine

## The two files

- Both hold one JSON object; comments and trailing commas are allowed
- The keys end with the flag they preset, e.g.
  `{"do": {"add": {"transitive": false}}}`
- `GgRc.load(ggLog:)` reads `~/.gg_rc` (`$GG_RC` names another file) and
  writes it with `builtInDefaults` when missing; `repo:` reads `.gg/gg_rc`
  on top
- `GgRc.loadRepo(repo)` reads only `.gg/gg_rc`; `create: true` writes a
  missing file with `repoDefaults` and adds `!.gg/gg_rc` below a `.gg/*`
  rule of `.gitignore`, so the file stays tracked
- An existing file is never rewritten; what it leaves out takes its default

## Repository settings

- `repoDefaults` lists the settings that belong to one repository, both
  `true` by default:
  - `do.upgrade.deps.majorVersions` (`GgRc.upgradeMajorVersions`) —
    whether dependency upgrades may cross major versions
  - `can.commit.checks` (`GgRc.commitChecks`) — whether the checks before
    a commit run
- `flag()` never reads them from `~/.gg_rc`; a `~/.gg_rc` that sets one
  loads as broken and names the repository file to use instead
- Because `~/.gg_rc` cannot hold them, a repository file that spells them
  out hides none of the user's settings

## Errors

- Invalid JSON or no object: loading succeeds, every `flag()` throws with
  the file and how to repair it — a run that reads no setting goes on
- A non-boolean value throws and names the file that holds it
- An unknown setting throws an `ArgumentError`

## Skippable command clusters

- `CommandCluster` got the optional parameter `checksSetting`
- When the repository file sets it to `false`, the commands are not run,
  `<shortDescription> skipped: <setting> is false in .gg/gg_rc.` is logged
  and the success state is recorded, so the gates reading it keep working
- The setting is read with `loadRepo` without `create`, so a check never
  writes into the repository

## Open Points

- New repository settings need an entry in `repoDefaults` with a default
  that keeps today's behavior
- A `.gitignore` with an unusual `.gg` rule is not rewritten; the file then
  stays ignored until the rule is fixed by hand
