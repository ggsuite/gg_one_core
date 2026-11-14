<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Run tasks in parallel, logged in order

## Motivation

- Commands built on this kernel do the same thing for many repositories.
  One after the other, most of the machine sits idle
- Doing it at once is easy to get wrong:
  - the output of the tasks gets mixed and cannot be read anymore
  - test runs side by side slow each other down into their timeouts
  - a remote throttles a client that opens too many connections
  - two runs in one repository overwrite each other's files
- The kernel is the lowest layer every command can reach, so the answers
  to these four problems live here, once

## Strategy

- One function, `runInParallel`, runs tasks at the same time and reports
  as if they had run in a loop
- One limit per kind of work (`GgParallelism`): local work follows the
  processors, work at a remote gets small fixed numbers. Parallel by
  default; `GG_PARALLEL=1` runs everything one after the other
- Test runs that share the machine share its test files and get more time
  per test; a run on its own keeps the whole machine
- One gg run at a time per repository (`RepoLock`), with a lock that
  cannot be left behind

## runInParallel: at once, but logged like a loop

- `runInParallel(count:, task:, ggLog:, maxParallel:, cancelOnError:)`
  runs at most `maxParallel` tasks at once and returns the results in
  task order
- Every task gets a log of its own. What the first unfinished task logs
  reaches `ggLog` right away, the rest is held back until it is its turn.
  The output reads like that of a loop, rewritten status lines included
- When tasks fail, the error of the first failed task **in task order**
  is thrown, with its stack trace, and no further task starts
- `cancelOnError: false`, for tasks that change something: the running
  tasks finish and are logged, nothing stops half way
- `cancelOnError: true`, for checks: the tasks after the failed one are
  cancelled and their output is dropped. Each task runs in a
  `GgProcessScope` of gg_process, whose cancel kills the processes the
  task started
- Before such a kill `waitForGitIndex` waits until git has written the
  index of the repository; a kill in between leaves `.git/index.lock`
- `CommandCluster` records its success inside `GgProcessScope.shield`, so
  a cancel cannot stop it between writing `.gg/gg.json` and the commit

## GgParallelism: one limit per kind of work

- `heavy` — test runs, analyzers, compilers: a quarter of the processors,
  at least 1, at most 4. Fewer than eight processors, a usual CI runner,
  means one at a time, as before. The cap is what was measured, and
  memory: about a gigabyte each for the analyzer and the test runner
- `light` — tasks waiting for short processes, e.g. a few git calls: the
  processors, 2 to 16
- Work at a remote gets fixed numbers: `network` 8 (`git fetch`,
  `ls-remote`, registry lookups), `pushes` 4, `pullRequests` 10 and
  `publishes` 4 (releases side by side)
- They do **not** grow with the machine: a host throttles by client, and
  a hundred repositories must never open a hundred connections
- A host also counts how many pull requests **start** within a minute and
  an hour. That count is kept where the pull requests are created
- `GG_PARALLEL=<n>` sets `heavy` and caps all others. It never raises a
  limit for remote work

## A test run gets its share of the machine

- A test runner takes half of the processors for its test files, as if
  the machine were its own
- Measured on 22 processors, Windows, twelve suites: four runs at once
  with 11 test files each ran dozens of tests into the 30 s timeout. With
  three test files per run no test timed out, and the suites took 176 s
  instead of 254 s one after the other
- A full check of eleven repositories — pub get, analyze, format, tests —
  took 306 s one at a time and 156–170 s with `GG_PARALLEL=4`, three
  times without a failure
- `TaskSlots(n).use(body)` lets only `n` bodies run at once. Tasks run
  with the `light` limit and hand their heavy part to
  `TaskSlots.heavy()`: a task that only confirms an earlier result never
  waits behind a test run
- `GgParallelism.testFilesPerRun` is the share of a run in a heavy slot:
  what one run would take, divided by the runs that hold a slot or wait
  for one. `Checks` hands it to gg_test's `Tests(concurrency:)`
- The share follows the runs under way, not the limit. The only run gets
  the whole machine: a suite of 39 test files took 111 s with three at a
  time and 90 s with the runner's eleven
- `GgParallelism.testTimeoutFactor` gives a test in a heavy slot as many
  times its usual time as there are slots (`Tests(timeoutFactor:)`):
  sharing made single suites up to three times as slow. A test that hangs
  still ends, after two minutes instead of half a minute

## RepoLock: one gg run at a time in a repository

- The commands of a `CommandCluster` write into the repository: coverage,
  generated test files, the state file and its commit. Two runs side by
  side — two terminals, a developer and an agent — spoil each other: one
  failed with »The test files exist but produced no coverage for their
  implementation file«, and both took three times as long
- `CommandCluster` now runs its commands inside `RepoLock.use`. A second
  run logs »Another gg run works in `<repo>`. Waiting for it …«, waits
  and then asks the recorded state again: when the first run checked this
  very state, the second prints its `✓` and runs nothing
- The lock is the file `.git/gg-run-lock`, so git neither tracks nor
  shows it. It names its holder and an **expiry date**
- The holder renews the lock every 10 s. A lock not renewed for 30 s is
  free again, whatever became of its holder: a run that was killed or
  hangs leaves no lock behind
- Reading the file and writing it anew is one step, guarded by a lock of
  the operating system that is held for that step only

## Dependency updates

- gg_process: `GgProcessScope` with `cancel` and `shield`; `ggPlatform`
  reports the number of processors
- gg_test: `Tests(concurrency:)` and `Tests(timeoutFactor:)`

## Open Points

- The gain of test runs side by side is modest: one run of a suite that
  starts many processes already keeps the machine busy
- `RepoLock` covers the commands of a cluster only, not a test run
  started on its own or flows that change a repository outside a cluster.
  A directory without `.git` is not protected at all
- The remote limits are fixed numbers, not read from the host. A request
  turned away all the same is repeated by gg_git's `GitRetry`
- Collaborators of a command that runs repositories in parallel must not
  keep the state of a run in their fields: one instance serves all tasks
