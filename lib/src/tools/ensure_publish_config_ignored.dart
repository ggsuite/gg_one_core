// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_git/gg_git.dart' show ggCommitPrefix;
import 'package:gg_log/gg_log.dart';
import 'package:gg_process/gg_process.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart';

import 'ensure_gg_json_not_ignored.dart';
import 'gg_state.dart';
import 'pubspec_overrides_backup.dart';

/// Makes sure the files a publish writes beside the release are listed in a
/// repository's `.gitignore`: the runtime publish file `.gg/gg-publish.json`
/// and the `pubspec_overrides.yaml` backup at [pubspecOverridesBackupPath].
///
/// Both must be invisible to git: as untracked files they would break every
/// is-committed check in the middle of a publish, and as tracked files their
/// churn would pollute the history. This helper appends the missing entries
/// and — in the standalone gg_one flow — commits the `.gitignore` change
/// right away, transplanting the recorded check hashes via
/// [GgState.updateHash] so analyze/test results stay valid.
///
/// Before touching anything, [EnsureGgJsonNotIgnored] heals or rejects
/// ignore rules that exclude the tracked state file — so the bootstrap
/// commit below can always add `.gg/gg.json`.
class EnsurePublishConfigIgnored {
  /// Constructor.
  EnsurePublishConfigIgnored({
    required this.ggLog,
    GgState? state,
    EnsureGgJsonNotIgnored? ggJsonGuard,
    GgProcessWrapper processWrapper = const GgProcessWrapper(),
  }) : _state = state ?? GgState(ggLog: ggLog),
       _processWrapper = processWrapper {
    _ggJsonGuard =
        ggJsonGuard ??
        EnsureGgJsonNotIgnored(
          ggLog: ggLog,
          state: _state,
          processWrapper: processWrapper,
        );
  }

  /// The logger used for logging.
  final GgLog ggLog;

  final GgState _state;
  final GgProcessWrapper _processWrapper;
  late final EnsureGgJsonNotIgnored _ggJsonGuard;

  /// The `.gitignore` entry that hides the runtime publish file from git.
  static const String entry = '.gg/gg-publish.json';

  /// All `.gitignore` entries this helper maintains: the runtime publish
  /// file and the workspace-wiring backups a publish writes
  /// (`pubspec_overrides.yaml` for Dart, `pnpm-workspace.yaml` for
  /// pnpm-managed TypeScript).
  static const List<String> entries = [
    entry,
    pubspecOverridesBackupPath,
    pnpmWorkspaceBackupPath,
  ];

  /// Ensures [entries] are present in `<directory>/.gitignore`. Returns true
  /// when the file was changed (or created). With [commit] the change is
  /// committed immediately (only `.gitignore` plus the hash-transplanted
  /// `.gg/gg.json` — other working-tree changes are left alone); without it
  /// the caller's next commit is expected to pick the change up.
  Future<bool> ensure({
    required Directory directory,
    bool commit = true,
  }) async {
    // .gg/gg.json joins the bootstrap commit below — heal or reject ignore
    // rules that would make »git add« refuse the explicitly named path.
    await _ggJsonGuard.ensure(directory: directory);

    final gitignore = File(join(directory.path, '.gitignore'));
    final content = gitignore.existsSync() ? gitignore.readAsStringSync() : '';
    final lines = content.split('\n').map((line) => line.trim()).toSet();
    final missing = entries.where((entry) => !lines.contains(entry)).toList();
    if (missing.isEmpty) {
      return false;
    }

    // Capture the hash before the change so recorded check results can be
    // transplanted onto the new content (same pattern as the changelog and
    // version-bump commits in »do publish«).
    final hashBefore = commit
        ? await _state.currentHash(directory: directory, ggLog: ggLog)
        : null;

    final glue = content.isEmpty || content.endsWith('\n') ? '' : '\n';
    gitignore.writeAsStringSync('$content$glue${missing.join('\n')}\n');

    if (commit) {
      await _state.updateHash(hash: hashBefore!, directory: directory);
      await _commitGitignore(directory);
      ggLog('Added ${missing.join(', ')} to .gitignore.');
    }
    return true;
  }

  /// Commits only `.gitignore` and the hash-transplanted `.gg/gg.json`, so
  /// unrelated working-tree changes are never swept into this commit.
  Future<void> _commitGitignore(Directory directory) async {
    final paths = <String>['.gitignore'];
    if (File(join(directory.path, '.gg', 'gg.json')).existsSync()) {
      paths.add('.gg/gg.json');
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
      '${ggCommitPrefix}Ignore the publish runtime files of gg',
      '--',
      ...paths,
    ], workingDirectory: directory.path);
    if (result.exitCode != 0) {
      throw Exception(
        cError(
          'Committing the .gitignore entry for $entry failed: ${result.stderr}',
        ),
      );
    }
  }
}

/// Mock for [EnsurePublishConfigIgnored].
class MockEnsurePublishConfigIgnored extends Mock
    implements EnsurePublishConfigIgnored {}
