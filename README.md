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

## Running tasks in parallel

- `runInParallel(count:, task:, ggLog:, maxParallel:, cancelOnError:)` runs
  tasks at the same time and logs them as if they had run in a loop
- `GgParallelism` holds one limit per kind of work: `heavy` (test runs,
  analyzers) a quarter of the processors, 1 to 4; `light` the processors,
  2 to 16; `network` 8, `pushes` 4, `pullRequests` 10, `publishes` 4
- The environment variable `GG_PARALLEL=<n>` sets `heavy` and caps the
  others; `GG_PARALLEL=1` runs everything one after the other
- `TaskSlots.heavy()` are the slots for the heavy part of tasks; a test run
  in one of them shares the test files of the machine with the runs under
  way (`GgParallelism.testFilesPerRun`)

## One gg run per repository

- `RepoLock.use(directory:, ggLog:, body:)` lets one run at a time work in
  a repository; a second run waits and learns that it waited
- The lock is the file `.git/gg-run-lock` with its holder and an expiry
  date: renewed every 10 s, free again after 30 s without a renewal
- `CommandCluster` runs its commands inside of it and takes over the result
  of the run it waited for
