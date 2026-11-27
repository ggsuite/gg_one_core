<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Cross major versions only on request

## Motivation

- `GgRc` holds the settings of gg. `do.upgrade.deps.majorVersions` decides
  whether an upgrade of the dependencies crosses major versions
- It defaulted to `true`: every upgrade jumped to new majors unless a
  repository's `.gg/gg_rc` said otherwise
- A new major version can break a repository. It should come in when
  somebody asks for it, not as a side effect of every upgrade

## Strategy

- Change the default in `GgRc.repoDefaults` to `false`
- Leave existing repository files alone
- Adjust tests and documentation

## The new default

- `GgRc.repoDefaults` now holds
  `{"do": {"upgrade": {"deps": {"majorVersions": false}}}}`
- `flag(GgRc.upgradeMajorVersions)` answers `false` for a repository
  without the setting
- `loadRepo(repo, create: true)` writes the new default into a missing
  `.gg/gg_rc`
- A repository that wants majors sets `true` in its `.gg/gg_rc`; a caller
  that passes the value explicitly still wins
- `can.commit.checks` keeps its default `true`

## Existing files

- `loadRepo(create: true)` spelled every default out, so many repositories
  track a `.gg/gg_rc` that says `true`
- Repository files are never rewritten — a check must not dirty the tree —
  so those repositories keep crossing majors when an upgrade runs
- Unlike the user file, there is no »former defaults« migration for
  repository files: a tracked file is part of the repository's history

## Tests

- The defaults test, the precedence test and the »never from the user
  file« test expect `false` now
- The comment test writes `true` and reads it back

## Open Points

- Tracked `.gg/gg_rc` files with `true` stay as they are; set them to
  `false` where a repository should not cross majors on an upgrade
