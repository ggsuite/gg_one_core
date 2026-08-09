// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:io';

import 'package:gg_git/gg_git.dart';
import 'package:gg_log/gg_log.dart';
import 'package:mocktail/mocktail.dart' as mocktail;

import 'package:gg_one_core/src/tools/gg_owned_files.dart';
import 'package:gg_one_core/src/tools/gg_state.dart';
import 'package:gg_one_core/src/tools/ticket_description.dart';

// #############################################################################
/// Produces the message for the commit that saves the user changes gg found
/// in the working tree when it was about to write a bookkeeping commit.
typedef UserCommitMessageBuilder = FutureOr<String?> Function(Directory repo);

// #############################################################################
/// What [GgSystemCommit.commit] did.
class GgSystemCommitResult {
  /// Constructor
  const GgSystemCommitResult({
    required this.userCommitCreated,
    required this.systemCommitCreated,
    required this.ggOwnedPaths,
    required this.foreignPaths,
    this.userCommitMessage,
  });

  /// Whether a prefix-less commit carrying user changes was created first.
  final bool userCommitCreated;

  /// Whether the »#gg: « bookkeeping commit itself was created.
  final bool systemCommitCreated;

  /// The gg-owned paths that went into the bookkeeping commit.
  final List<String> ggOwnedPaths;

  /// The foreign paths that went into the user commit.
  final List<String> foreignPaths;

  /// The message of the user commit, when one was created.
  final String? userCommitMessage;
}

// #############################################################################
/// Writes gg's bookkeeping commits — and nothing but bookkeeping.
///
/// The »#gg: « prefix is a contract: such a commit contains gg's own files
/// only, and it exists only on a feature branch. This class enforces both
/// ends of the contract for every producer:
///
/// 1. **Foreign changes are saved first.** Anything dirty that gg does not
///    own goes into its own commit *without* the prefix, so the user's work
///    stays visible as work — the message comes from the injected builder,
///    falling back to the ticket description and finally to
///    »Save pending changes on `<branch>`«.
/// 2. **The bookkeeping commit is pathspec-scoped** to gg-owned files, so it
///    can never sweep anything else in — not even entries someone staged
///    beforehand.
/// 3. **No commit is ever written outside a feature branch.** On `main`,
///    `master` or a detached HEAD the call throws — the default branch only
///    ever receives release merges and tags.
class GgSystemCommit {
  /// Constructor
  GgSystemCommit({
    required this.ggLog,
    GitStatus? gitStatus,
    Commit? commitCommand,
    IsFeatureBranch? isFeatureBranch,
    LocalBranch? localBranch,
    HeadMessage? headMessage,
    GgState? state,
  }) : _gitStatus = gitStatus ?? GitStatus(ggLog: ggLog),
       _commit = commitCommand ?? Commit(ggLog: ggLog),
       _isFeatureBranch = isFeatureBranch ?? IsFeatureBranch(ggLog: ggLog),
       _localBranch = localBranch ?? LocalBranch(ggLog: ggLog),
       _headMessage = headMessage ?? HeadMessage(ggLog: ggLog),
       _state = state ?? GgState(ggLog: ggLog);

  /// The logger used for logging
  final GgLog ggLog;

  final GitStatus _gitStatus;
  final Commit _commit;
  final IsFeatureBranch _isFeatureBranch;
  final LocalBranch _localBranch;
  final HeadMessage _headMessage;
  final GgState _state;

  // ...........................................................................
  /// Commits the gg-owned changes of [directory] as [message].
  ///
  /// [message] must carry the »#gg: « prefix — it is the claim this class
  /// enforces.
  ///
  /// [paths] narrows the bookkeeping commit to the given repo-relative paths;
  /// every one of them must be gg-owned. When null, all dirty gg-owned files
  /// are taken. Either way only paths that are actually dirty are committed —
  /// a clean tree yields no commit and no error.
  ///
  /// [includeUntracked] controls whether untracked files count as dirty. Turn
  /// it off at call sites that must not sweep up build output.
  ///
  /// [ammendWhenNotPushed] folds the bookkeeping commit into HEAD — but only
  /// when HEAD is itself an unpushed gg commit and no user commit was just
  /// created. Amending a *user* commit would smuggle gg files under the
  /// user's message, the inverse of the bug this class exists to prevent.
  ///
  /// [userCommitMessage] supplies the message for the commit that saves
  /// foreign changes. When it is missing or answers empty, the ticket
  /// description found above [directory] is used, then a branch-based
  /// fallback.
  ///
  /// [stateKey] — when set, the state is recorded via [GgState.writeSuccess]
  /// after the commits, so check results survive (e.g. `doCommit`).
  Future<GgSystemCommitResult> commit({
    required Directory directory,
    required GgLog ggLog,
    required String message,
    List<String>? paths,
    bool includeUntracked = true,
    bool ammendWhenNotPushed = false,
    UserCommitMessageBuilder? userCommitMessage,
    String? stateKey,
  }) async {
    if (!isGgGenerated(message)) {
      throw ArgumentError(
        'The message of a system commit must start with »$ggCommitPrefix«. '
        'Got: »$message«',
      );
    }

    // Explicit paths are the caller's claim about what it changed — verify
    // the claim instead of trusting it, so a wrong list fails loudly and not
    // by swallowing user files into a »#gg: « commit.
    if (paths != null) {
      for (final path in paths) {
        if (!isGgOwnedPath(path)) {
          throw ArgumentError(
            'A system commit may only contain gg-owned files, '
            'but »$path« is not one.',
          );
        }
      }
    }

    final entries = await _gitStatus.get(
      directory: directory,
      ggLog: ggLog,
      includeUntracked: includeUntracked,
    );

    final unmerged = entries.where((e) => e.isUnmerged).toList();
    if (unmerged.isNotEmpty) {
      throw Exception(
        'Cannot commit: the repository has unresolved merge conflicts '
        '(${unmerged.map((e) => e.path).join(', ')}). Resolve them first.',
      );
    }

    // Split the dirty entries by ownership. A rename counts as one unit: when
    // its two names classify differently, the user's content is what moved,
    // so the whole entry is foreign.
    //
    // Each side also collects what actually needs `git add`: only the new
    // name of an entry, and only when the entry has an unstaged side — the
    // old name of a staged rename matches neither working tree nor index, so
    // »git add« refuses it, while the commit pathspec must still carry it.
    final ggOwnedDirty = <String>[];
    final ggOwnedToStage = <String>[];
    final foreign = <String>[];
    final foreignToStage = <String>[];
    for (final entry in entries) {
      final needsStaging = entry.y != ' ';
      if (entry.paths.every(isGgOwnedPath)) {
        ggOwnedDirty.addAll(entry.paths);
        if (needsStaging) {
          ggOwnedToStage.add(entry.path);
        }
      } else {
        foreign.addAll(entry.paths);
        if (needsStaging) {
          foreignToStage.add(entry.path);
        }
      }
    }

    // The paths the bookkeeping commit takes: the caller's list — reduced to
    // what is actually dirty, because git rejects a pathspec matching
    // nothing — or everything gg owns.
    final dirtySet = ggOwnedDirty.toSet();
    final ggPaths = paths == null
        ? ggOwnedDirty
        : paths.where(dirtySet.contains).toList();

    if (ggPaths.isEmpty && foreign.isEmpty) {
      return const GgSystemCommitResult(
        userCommitCreated: false,
        systemCommitCreated: false,
        ggOwnedPaths: [],
        foreignPaths: [],
      );
    }

    // No commit outside a feature branch — the default branch only ever
    // receives release merges and tags.
    await _throwWhenNotOnFeatureBranch(directory);

    // Save the user's work first, under its own prefix-less message.
    String? resolvedUserMessage;
    var userCommitCreated = false;
    if (foreign.isNotEmpty) {
      resolvedUserMessage = await _resolveUserMessage(
        directory,
        userCommitMessage,
      );
      await _commit.commit(
        directory: directory,
        ggLog: ggLog,
        doStage: true,
        message: resolvedUserMessage,
        paths: foreign,
        stagePaths: foreignToStage,
      );
      userCommitCreated = true;
      ggLog(
        'Saved pending user changes as »$resolvedUserMessage« '
        '(${foreign.length} file(s)).',
      );
    }

    // The bookkeeping commit itself.
    var systemCommitCreated = false;
    if (ggPaths.isNotEmpty) {
      final mayAmend =
          ammendWhenNotPushed &&
          !userCommitCreated &&
          await _headIsGgCommit(directory);
      final ggPathSet = ggPaths.toSet();
      await _commit.commit(
        directory: directory,
        ggLog: ggLog,
        doStage: true,
        message: message,
        paths: ggPaths,
        stagePaths: ggOwnedToStage.where(ggPathSet.contains).toList(),
        ammendWhenNotPushed: mayAmend,
      );
      systemCommitCreated = true;
    }

    if (stateKey != null) {
      await _state.writeSuccess(directory: directory, key: stateKey);
    }

    return GgSystemCommitResult(
      userCommitCreated: userCommitCreated,
      systemCommitCreated: systemCommitCreated,
      ggOwnedPaths: ggPaths,
      foreignPaths: foreign,
      userCommitMessage: resolvedUserMessage,
    );
  }

  // ...........................................................................
  /// Throws when [directory] is not on a feature branch.
  Future<void> _throwWhenNotOnFeatureBranch(Directory directory) async {
    final isFeature = await _isFeatureBranch.get(
      directory: directory,
      ggLog: (_) {}, // coverage:ignore-line
    );
    if (isFeature) {
      return;
    }

    final branch = await _localBranch.get(
      directory: directory,
      ggLog: (_) {}, // coverage:ignore-line
    );
    final where = branch.isEmpty ? 'a detached HEAD' : 'branch »$branch«';
    throw Exception(
      'Cannot write a gg commit on $where. '
      'gg commits exist on feature branches only — '
      'the default branch receives release merges and tags, nothing else.',
    );
  }

  // ...........................................................................
  /// Whether HEAD is itself a gg-generated commit.
  Future<bool> _headIsGgCommit(Directory directory) async {
    final head = await _headMessage.get(
      directory: directory,
      ggLog: (_) {}, // coverage:ignore-line
      throwIfNotEverythingIsCommitted: false,
    );
    return isGgGenerated(head);
  }

  // ...........................................................................
  /// The message for the commit saving foreign changes.
  ///
  /// Priority: the injected [builder] → the ticket description found above
  /// the repository → »Save pending changes on `<branch>`«.
  Future<String> _resolveUserMessage(
    Directory directory,
    UserCommitMessageBuilder? builder,
  ) async {
    var message = (await builder?.call(directory))?.trim() ?? '';

    if (message.isEmpty) {
      message = readTicketDescriptionForRepo(directory)?.trim() ?? '';
    }

    if (message.isEmpty) {
      final branch = await _localBranch.get(
        directory: directory,
        ggLog: (_) {}, // coverage:ignore-line
      );
      message = branch.isEmpty
          ? 'Save pending changes'
          : 'Save pending changes on $branch';
    }

    // A user commit that looks generated would make PublishSkipCheck treat
    // the user's work as bookkeeping and skip its release — exactly the data
    // loss this class prevents. Rewrite instead of failing: the work still
    // has to be saved.
    if (isGgGenerated(message)) {
      message = 'Save pending changes ($message)';
    }

    return message;
  }
}

/// Mocktail mock
class MockGgSystemCommit extends mocktail.Mock implements GgSystemCommit {}
