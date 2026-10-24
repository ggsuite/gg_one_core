<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Explain failed pana runs and count DNA commits as gg's own

## Motivation

- The checks of this repo must work on Windows as on macOS and Linux, and a
  check that fails must say why
- On Windows, the pana check failed with nothing but
  "Error parsing pana output: FormatUnexpected end of input"
- The cause stayed hidden: pana 0.23.17 and later reject every Windows temp
  folder as sandbox output folder, because its path contains ":", and exit
  with code 1 and an empty stdout
- Ticket gg-1 also regenerated the DNA of the repo; its
  `#gg: generated DNA` commits change guides, skills and hooks
- These files are not gg's own, so the commits counted as manual work, and
  a repo whose only change was the new DNA looked as if it had work to
  commit and release

## Strategy

- Keep pana's JSON report as the only source of the score
- Tell "pana printed no report" apart from "the report cannot be read"
- Take the reason from what pana writes anyway: its exit code and the JSON
  log on stderr
- Show only the lines that name the failure, no stack traces
- Leave pana's version to the developer: `Pana` neither pins nor upgrades it
- Trust the list the DNA writes of its files, `dna/_generated.json`
- Count only what is provably generated as bookkeeping

## Implementation 1: Report why pana printed no report

- `Pana` reads stdout from the first `{` on, as before
- Without a `{`, the error reads
  "pana printed no JSON report (exit code N)."
- JSON that does not decode reads "pana printed no valid JSON report
  (exit code N): " followed by the `FormatException`
- Both list the SEVERE and SHOUT records of pana's `--json` log on stderr,
  as `LEVEL: message — first line of error`
- Stack traces, other levels and further lines of an error are left out
- A stderr without such records is shown by its last ten lines
- JSON that parses but lacks the scores keeps "Error parsing pana output"
- On Windows, the check now names the actual problem:

```text
pana printed no JSON report (exit code 1).
SEVERE: Sandbox output folder must not contain ":"
```

- The tests cover a log with SEVERE and SHOUT records, a stderr without
  records, and JSON that is no report; CLAUDE.md describes both cases

## Implementation 2: Count the DNA's generated files as gg's own

- `ContributedCommits.manualCommitReason` tells manual work from gg's
  bookkeeping; callers use the answer to skip a commit or a release
- The new constant `ggGeneratedDnaMessage` names the subject the DNA engine
  commits with: `#gg: generated DNA`
- In such a commit, the files `dna/_generated.json` lists count as
  bookkeeping; the list is read after and before the commit, so a file the
  DNA removed counts too
- The list itself counts as well, and `CLAUDE.md` when the DNA writes its
  block there
- Still manual work: a file the list does not name, a missing or unreadable
  list, and a listed file that another `#gg:` commit changes
- The commit before is read as `<hash>~1`, not `<hash>^`: cmd.exe, which
  runs git on Windows, eats the caret
- New tests cover these cases with real git repositories

## Dependency updates

- gg_process starts commands the PATH holds only as `.bat` or `.cmd`, like
  `flutter` and the `dart` of the Flutter SDK, through the shell on Windows;
  `pub get --offline`, analyze, format and the pana install now start there
- gg_test no longer asks for coverage of an implementation file whose test
  file excludes the platform with a file-level `@TestOn`
- Both arrive with the next releases of these packages, within the current
  version constraints
- dna_ggsuite ^1.0.0 brings the `/gg-review` skill, refreshed ticket and
  commit skills, a hook that keeps prompts in a project management repo,
  and code guides without a package prefix for type names

## Result

- A pana run that dies before its report names its exit code and the cause
- A repo whose only change is a regenerated DNA counts as unchanged

## Open Points

- pana 0.23.17 and later still fail on Windows; the check now says why,
  the fix belongs to pana
- The full log of a failed run is only visible when pana is run by hand
