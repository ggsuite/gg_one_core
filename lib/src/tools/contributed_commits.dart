// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_git/gg_git.dart';
import 'package:mocktail/mocktail.dart';
import 'package:yaml/yaml.dart';

import 'package:gg_one_core/src/tools/gg_commit_message.dart';
import 'package:gg_one_core/src/tools/gg_owned_files.dart';
import 'package:gg_one_core/src/tools/gg_state.dart';

// #############################################################################
/// Tells manual work from gg's own bookkeeping in the commits a ticket
/// contributes.
///
/// Contributed means: not reachable from the main branch — work already
/// merged there is not a change of this ticket — and newer than the last
/// merge-back commit of an earlier release. gg squash-merges, so the original
/// feature commits never become ancestors of the main branch and would
/// otherwise linger in the range forever.
///
/// Two readers share the answer: `gg do commit`, which must do nothing when
/// gg's own commits are all there is, and `PublishSkipCheck`, which skips the
/// release of such a repository. One predicate for both — otherwise the one
/// writing a CHANGELOG entry invents the very change the other then has to
/// release.
///
/// A `#gg:` commit counts as manual work when it touches a file gg does not
/// own, or when it changes which dependencies a manifest offers its
/// consumers (pubspec `dependencies`; package.json `dependencies`,
/// `peerDependencies`, `optionalDependencies`). Constraint changes and dev
/// dependencies stay bookkeeping.
///
/// Every situation that cannot be judged reliably (missing git history,
/// unreachable branch, unparsable manifest, …) counts as manual work:
/// skipping is only ever chosen when it is provably safe.
class ContributedCommits {
  /// Constructor
  ContributedCommits({ProcessRunner? processRunner})
    : _processRunner = processRunner ?? defaultProcessRunner;

  /// Runs the git commands used to inspect the repository history.
  final ProcessRunner _processRunner;

  // ...........................................................................
  /// Returns why the commits [directory] contributes contain manual work, or
  /// null when every one of them is gg's own bookkeeping.
  ///
  /// The working tree is not inspected — a caller that cares about pending
  /// changes has already asked git about them (`gg do commit` through
  /// `IsCommitted`, `PublishSkipCheck` through its own status call), and the
  /// two have different answers for the same dirt: a lock file rewritten
  /// behind everybody's back is no manual change, an edited source file is.
  Future<String?> manualCommitReason({required Directory directory}) async {
    try {
      final mainRef = await _mainRef(directory);
      if (mainRef == null) {
        return 'no main branch to compare against was found';
      }

      // Everything reachable from the main branch is already on it, and
      // everything up to the last merge-back is already released — what is
      // left is exactly what this ticket contributes.
      final anchor = await _lastMergeBackCommit(directory);
      final commits = await _runGit(<String>[
        'log',
        '--no-merges',
        '--format=%H%x09%s',
        'HEAD',
        '--not',
        mainRef,
        ?anchor,
      ], repoDir: directory);

      for (final line in commits.split('\n')) {
        final entry = line.trim();
        if (entry.isEmpty) {
          continue;
        }
        final tab = entry.indexOf('\t');
        final hash = tab < 0 ? entry : entry.substring(0, tab);
        final subject = tab < 0 ? '' : entry.substring(tab + 1).trim();

        final files = await _filesOf(hash, directory);

        if (!isGgGenerated(subject)) {
          // A commit that touches nothing but derived bookkeeping — a
          // CHANGELOG entry, gg's state file, a lock file — carries no work
          // to release, whatever its message says. Those are exactly the
          // files the state hash ignores, so both answers agree. A commit
          // without any file is not one of them: an empty manual commit
          // cannot be judged and therefore counts as work.
          if (files.isNotEmpty && files.every(_isDerivedPath)) {
            continue;
          }
          return 'the repo contains the manual commit »$subject«';
        }

        // gg's ref commits are force commits — they sweep pending user
        // edits into the bookkeeping commit. A gg-labeled commit touching
        // a non-gg file therefore carries user work and blocks the skip.
        // An empty »#gg: « commit names no file and stays bookkeeping — gg
        // wrote it, so there is nothing to attribute to anybody else.
        final swallowedFile = files.firstWhere(
          (file) => !isGgOwnedPath(file),
          orElse: () => '',
        );
        if (swallowedFile.isNotEmpty) {
          return 'the gg commit »$subject« also changes »$swallowedFile«';
        }

        // A dependency added to or removed from a manifest is user work.
        final dependencyChange = await _dependencyChange(
          hash,
          files,
          directory,
        );
        if (dependencyChange != null) {
          return 'the gg commit »$subject« $dependencyChange';
        }
      }

      return null;
    } catch (e) {
      // A history that cannot be inspected cannot prove the repo unchanged.
      return 'the git history could not be inspected ($e)';
    }
  }

  // ######################
  // Private
  // ######################

  /// Consumer-visible dependency sections per manifest; dev deps never count.
  static const Map<String, List<String>> _dependencySections = {
    'pubspec.yaml': ['dependencies'],
    'package.json': [
      'dependencies',
      'peerDependencies',
      'optionalDependencies',
    ],
  };

  // ...........................................................................
  /// Whether [filePath] holds content gg derives rather than work someone
  /// did — the files [GgState.ignoreFiles] keeps out of the state hash.
  ///
  /// Matched by basename as well as by full path, and `.gg` at any depth:
  /// a repository may keep its package in a subfolder and git then reports
  /// »packages/x/CHANGELOG.md«. Matching the full path only would classify
  /// exactly those as work — and would disagree with [isGgOwnedPath] three
  /// lines further down, which matches basenames for the same reason.
  bool _isDerivedPath(String filePath) {
    final segments = filePath.split('/');
    if (segments.contains(ggDirName)) {
      return true;
    }
    return isIgnoredFile(filePath, GgState.ignoreFiles) ||
        isIgnoredFile(segments.last, GgState.ignoreFiles);
  }

  // ...........................................................................
  /// Describes how commit [hash] changes the dependency names of one of the
  /// manifests in [files], or null when it only touches their constraints.
  Future<String?> _dependencyChange(
    String hash,
    List<String> files,
    Directory repoDir,
  ) async {
    for (final file in files) {
      final sections = _dependencySections[file.split('/').last];
      if (sections == null) {
        continue;
      }
      // `~1`, not `^`: cmd.exe, which runs git on Windows, eats the caret.
      final before = await _dependencyNames('$hash~1', file, sections, repoDir);
      final after = await _dependencyNames(hash, file, sections, repoDir);
      if (before == null || after == null) {
        return 'changes »$file«, whose dependencies cannot be read';
      }

      final added = after.difference(before).toList()..sort();
      final removed = before.difference(after).toList()..sort();
      if (added.isEmpty && removed.isEmpty) {
        continue;
      }
      final changes = [
        if (added.isNotEmpty) 'added: ${added.join(', ')}',
        if (removed.isNotEmpty) 'removed: ${removed.join(', ')}',
      ];
      return 'changes the dependencies of »$file« (${changes.join('; ')})';
    }
    return null;
  }

  // ...........................................................................
  /// The names [sections] of manifest [file] declare at revision [rev]:
  /// none for a missing file, null for an unparsable one, which the caller
  /// counts as a change — undecidable means work.
  Future<Set<String>?> _dependencyNames(
    String rev,
    String file,
    List<String> sections,
    Directory repoDir,
  ) async {
    final content = await _runGit(
      <String>['show', '$rev:$file'],
      repoDir: repoDir,
      allowFailure: true,
    );
    final Object? manifest;
    try {
      manifest = file.endsWith('.json')
          ? jsonDecode(content)
          : loadYaml(content);
    } on FormatException {
      return content.isEmpty ? <String>{} : null;
    }

    if (manifest == null) {
      return <String>{};
    }
    if (manifest is! Map) {
      return null;
    }
    final result = <String>{};
    for (final section in sections) {
      final entries = manifest[section];
      if (entries is Map) {
        result.addAll(entries.keys.map((key) => '$key'));
      } else if (entries != null) {
        return null;
      }
    }
    return result;
  }

  // ...........................................................................
  /// The repo-relative paths commit [hash] changes, as git prints them.
  Future<List<String>> _filesOf(String hash, Directory repoDir) async {
    final files = await _runGit(<String>[
      'show',
      '--name-only',
      '--format=',
      hash,
    ], repoDir: repoDir);
    return files
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  // ...........................................................................
  /// The main branch the repository is compared against.
  ///
  /// The branch the remote declares as its default (`origin/HEAD`) comes
  /// first — a repository releasing from `develop` is compared against
  /// `develop`, not against a `main` it may still carry. Then
  /// `origin/<main>` — it is what everybody else sees — with the local
  /// branch as fallback for a repository whose remote is unreachable. Null
  /// when none exists, which counts as undecidable and therefore as manual
  /// work.
  Future<String?> _mainRef(Directory repoDir) async {
    final declared = await _declaredDefaultBranch(repoDir);
    final candidates = [
      if (declared != null) ...['origin/$declared', declared],
      'origin/main',
      'origin/master',
      'main',
      'master',
    ];
    for (final candidate in candidates) {
      final sha = await _runGit(
        <String>['rev-parse', '--verify', '--quiet', candidate],
        repoDir: repoDir,
        allowFailure: true,
      );
      if (sha.isNotEmpty) {
        return candidate;
      }
    }
    return null;
  }

  // ...........................................................................
  /// The branch `refs/remotes/origin/HEAD` points at, or null when the
  /// remote declares no default branch.
  Future<String?> _declaredDefaultBranch(Directory repoDir) async {
    final target = await _runGit(
      <String>[
        'symbolic-ref',
        '--quiet',
        '--short',
        'refs/remotes/origin/HEAD',
      ],
      repoDir: repoDir,
      allowFailure: true,
    );
    const prefix = 'origin/';
    if (!target.startsWith(prefix) || target.length == prefix.length) {
      return null;
    }
    return target.substring(prefix.length);
  }

  // ...........................................................................
  /// The last commit that folded a released main branch back into this
  /// feature branch, or null when the branch never carried a release.
  ///
  /// Matched by the shared [ggMergeBackPrefix], so producer and reader
  /// cannot drift apart.
  Future<String?> _lastMergeBackCommit(Directory repoDir) async {
    final hash = await _runGit(
      <String>[
        'log',
        '-1',
        '--format=%H',
        // A fixed string, not a pattern — the prefix carries no regex meta
        // characters today, and --fixed-strings keeps it that way.
        '--fixed-strings',
        '--grep=$ggMergeBackPrefix',
        'HEAD',
      ],
      repoDir: repoDir,
      allowFailure: true,
    );
    return hash.isEmpty ? null : hash;
  }

  // ...........................................................................
  /// Runs git with [args] in [repoDir] and returns the trimmed stdout.
  Future<String> _runGit(
    List<String> args, {
    required Directory repoDir,
    bool allowFailure = false,
  }) => runGit(
    _processRunner,
    args,
    repoDir: repoDir,
    allowFailure: allowFailure,
  );
}

/// Mocktail mock
class MockContributedCommits extends Mock implements ContributedCommits {}
