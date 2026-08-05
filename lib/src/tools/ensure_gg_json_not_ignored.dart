// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_process/gg_process.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart';

import 'gg_state.dart';

/// Makes sure no gitignore rule excludes `.gg/gg.json`.
///
/// The state file carries the recorded check results and is meant to be
/// tracked — an excluded one never reaches CI, and »git add« refuses the
/// explicitly named path, which crashed »do publish« half way through its
/// `.gitignore` bootstrap. Simple rules in the repository's root
/// `.gitignore` (».gg«, ».gg/«, ».gg/*«, a literal ».gg/gg.json«) are
/// rewritten to the canonical shape
///
///     .gg/*
///     !.gg/gg.json
///
/// — the other `.gg` runtime files stay invisible — and committed right
/// away, transplanting the recorded check hashes via [GgState.updateHash]
/// so analyze/test results stay valid. Rules that cannot be rewritten
/// safely (wildcards, nested ignore files, `.git/info/exclude`, a global
/// `core.excludesFile`) throw with the manual fix instead.
class EnsureGgJsonNotIgnored {
  /// Constructor.
  EnsureGgJsonNotIgnored({
    required this.ggLog,
    GgState? state,
    GgProcessWrapper processWrapper = const GgProcessWrapper(),
  }) : _state = state ?? GgState(ggLog: ggLog),
       _processWrapper = processWrapper;

  /// The logger used for logging.
  final GgLog ggLog;

  final GgState _state;
  final GgProcessWrapper _processWrapper;

  /// The state file that must stay visible to git.
  static const String ggJsonPath = '.gg/gg.json';

  /// Ensures no effective gitignore rule excludes [ggJsonPath] inside
  /// [directory]. Returns true when `.gitignore` was rewritten and
  /// committed, false when the file was not excluded in the first place.
  /// Throws when the offending rule lives outside the repository's root
  /// `.gitignore` or is no simple ».gg« rule — such a rule must be fixed
  /// by hand.
  Future<bool> ensure({required Directory directory}) async {
    if (_verifiedDirectories.contains(directory.path)) {
      return false;
    }

    if (!await _isIgnored(directory)) {
      _verifiedDirectories.add(directory.path);
      return false;
    }

    // Capture the hash before the change so recorded check results can be
    // transplanted onto the new content (same pattern as the .gitignore
    // bootstrap in EnsurePublishConfigIgnored).
    final hashBefore = await _state.currentHash(
      directory: directory,
      ggLog: ggLog,
    );

    // Git only reports the decisive rule, and removing it can surface the
    // next one (e.g. a literal ».gg/gg.json« line hiding a ».gg/« line
    // above it) — so one rule is rewritten per round.
    var rounds = 0;
    while (await _isIgnored(directory)) {
      // Every round removes at least one rule from .gitignore; the bound
      // only guards against a rule the rewrite failed to remove.
      if (rounds++ > 20) {
        throw Exception(cError(_manualFixMessage)); // coverage:ignore-line
      }
      _rewriteRule(directory, await _offendingRule(directory));
    }

    await _state.updateHash(hash: hashBefore, directory: directory);
    await _commitFix(directory);
    ggLog('Rewrote .gitignore: $ggJsonPath must not be ignored.');
    _verifiedDirectories.add(directory.path);
    return true;
  }

  // ######################
  // Private
  // ######################

  // ...........................................................................
  /// Directories already verified in this process. The guard runs on every
  /// check of every command — without the memo each writeSuccess would
  /// spawn a git process on that hot path.
  static final Set<String> _verifiedDirectories = {};

  // ...........................................................................
  /// True when git currently ignores [ggJsonPath] — through any effective
  /// rule (`.gitignore`, `.git/info/exclude`, a global `core.excludesFile`).
  /// Exit 1 (not ignored) and 128 (e.g. no git repository) both count as
  /// not ignored: outside a repository there is nothing to heal.
  Future<bool> _isIgnored(Directory directory) async {
    final result = await _processWrapper.run('git', [
      'check-ignore',
      '--quiet',
      '--',
      ggJsonPath,
    ], workingDirectory: directory.path);
    return result.exitCode == 0;
  }

  // ...........................................................................
  /// Asks git which rule excludes the state file and returns its source
  /// file, line number and pattern.
  Future<({String source, int line, String pattern})> _offendingRule(
    Directory directory,
  ) async {
    final result = await _processWrapper.run('git', [
      'check-ignore',
      '--verbose',
      '--',
      ggJsonPath,
    ], workingDirectory: directory.path);

    // Format: »<source>:<line>:<pattern><TAB><path>«
    final match = RegExp(
      r'^(.*?):(\d+):(.*)\t',
    ).firstMatch(result.stdout.toString());
    if (result.exitCode != 0 || match == null) {
      throw Exception(cError(_manualFixMessage));
    }

    return (
      source: match.group(1)!,
      line: int.parse(match.group(2)!),
      pattern: match.group(3)!,
    );
  }

  // ...........................................................................
  /// Rewrites the offending [rule] inside the repository's root
  /// `.gitignore`: a directory rule becomes the canonical pair
  /// ».gg/*« + »!.gg/gg.json«, a ».gg/*« rule just gains the negation, a
  /// literal ».gg/gg.json« rule is dropped. Duplicates of the rule are
  /// resolved in the same pass. Everything else throws.
  void _rewriteRule(
    Directory directory,
    ({String source, int line, String pattern}) rule,
  ) {
    const directoryRules = ['.gg', '.gg/', '/.gg', '/.gg/'];
    const starRules = ['.gg/*', '/.gg/*'];
    const literalRules = [ggJsonPath, '/$ggJsonPath'];
    final isFixable =
        directoryRules.contains(rule.pattern) ||
        starRules.contains(rule.pattern) ||
        literalRules.contains(rule.pattern);

    if (rule.source != '.gitignore' || !isFixable) {
      throw Exception(
        cError(
          'The rule »${rule.pattern}« in ${rule.source}:${rule.line} '
          'ignores $ggJsonPath.\n$_manualFixMessage',
        ),
      );
    }

    final gitignore = File(join(directory.path, '.gitignore'));
    final fixed = <String>[];
    var isRewritten = false;
    for (final line in gitignore.readAsStringSync().split('\n')) {
      if (line.trim() != rule.pattern) {
        fixed.add(line);
        continue;
      }
      if (literalRules.contains(rule.pattern) || isRewritten) {
        continue;
      }
      isRewritten = true;
      if (starRules.contains(rule.pattern)) {
        fixed.add(line); // ».gg/*« may stay — only the negation is missing
      } else {
        fixed.add('.gg/*');
      }
      fixed.add('!$ggJsonPath');
    }
    gitignore.writeAsStringSync(fixed.join('\n'));
  }

  // ...........................................................................
  /// Commits the rewritten `.gitignore` — plus the now trackable state file
  /// when it exists — so unrelated working-tree changes are never swept
  /// into this commit.
  Future<void> _commitFix(Directory directory) async {
    final paths = <String>['.gitignore'];
    if (File(join(directory.path, ggJsonPath)).existsSync()) {
      paths.add(ggJsonPath);
    }

    final add = await _processWrapper.run('git', [
      'add',
      ...paths,
    ], workingDirectory: directory.path);
    if (add.exitCode != 0) {
      throw Exception(
        cError('git add ${paths.join(' ')} failed: ${add.stderr}'),
      );
    }

    final result = await _processWrapper.run('git', [
      'commit',
      '-m',
      '#gg: Stop ignoring $ggJsonPath',
      '--',
      ...paths,
    ], workingDirectory: directory.path);
    if (result.exitCode != 0) {
      throw Exception(
        cError('Committing the .gitignore fix failed: ${result.stderr}'),
      );
    }
  }

  // ...........................................................................
  static const String _manualFixMessage =
      '$ggJsonPath must not be git-ignored: it carries the recorded check '
      'results and belongs into the repository.\n'
      'Please adjust your ignore rules so the file stays visible, e.g. '
      'replace ».gg/« in .gitignore with:\n'
      '  .gg/*\n'
      '  !$ggJsonPath';
}

/// Mock for [EnsureGgJsonNotIgnored].
class MockEnsureGgJsonNotIgnored extends Mock
    implements EnsureGgJsonNotIgnored {}
