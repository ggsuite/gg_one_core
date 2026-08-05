// @license
// Copyright (c) 2019 - 2024 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_direct_json/gg_direct_json.dart';
import 'package:gg_git/gg_git.dart';
import 'package:gg_lang/gg_lang.dart' as gg_lang;
import 'package:gg_log/gg_log.dart';
import 'package:path/path.dart';

import 'pubspec_overrides_backup.dart';

/// Stores and retrieves the state of the check commands
class GgState {
  /// Constructor
  GgState({
    required this.ggLog,
    LastChangesHash? lastChangesHash,
    IsCommitted? isCommitted,
    IsPushed? isPushed,
    ModifiedFiles? modifiedFiles,
    Commit? commit,
    HeadMessage? headMessage,
    HasRemote? hasRemote,
    CommitCount? commitCount,
  }) : _lastChangesHash = lastChangesHash ?? LastChangesHash(ggLog: ggLog),
       _isPushed = isPushed ?? IsPushed(ggLog: ggLog),
       _modifiedFiles = modifiedFiles ?? ModifiedFiles(ggLog: ggLog),
       _commit = commit ?? Commit(ggLog: ggLog),
       _headMessage = headMessage ?? HeadMessage(ggLog: ggLog),
       _hasRemote = hasRemote ?? HasRemote(ggLog: ggLog),
       _commitCount = commitCount ?? CommitCount(ggLog: ggLog);

  // ...........................................................................
  /// The logger used for logging
  final GgLog ggLog;

  // ...........................................................................
  /// The name of the state file inside `.gg`.
  static const configFileName = 'gg.json';

  /// The name earlier gg versions used, back when the files inside `.gg` were
  /// still hidden. Kept so an existing checkout can be migrated.
  static const legacyConfigFileName = '.gg.json';

  // ...........................................................................
  /// The file that might be ignored while reading the hash
  ///
  /// The entries are matched against the paths git reports, so the hidden
  /// names of the days before the files inside `.gg` were unhidden are listed
  /// as well: a repository being migrated carries both for one commit and
  /// must not look changed because of it.
  ///
  /// The lock files (`gg_lang.allLockFileNames`) are in here because they are
  /// tracked but *derived*: `pub get` rewrites them whenever a manifest is
  /// touched — including the run the Dart VS Code extension fires on its own.
  /// Without them every such rewrite would discard all recorded check results,
  /// and `_commitOrAmmendStateChanges` would stop amending, because then not
  /// only `.gg/gg.json` has changed.
  static final List<String> ignoreFiles = <String>[
    '.gg/',
    '.gg.json',
    '.gg/gg.json',
    '.gg/gg-publish.json',
    '.gg/.gg.json',
    '.gg/.gg-publish.json',
    pubspecOverridesBackupPath,
    pnpmWorkspaceBackupPath,
    'CHANGELOG.md',
    '.kidney_status',
    ...gg_lang.allLockFileNames,
  ];

  // ...........................................................................
  /// State keys of earlier gg versions that must not survive in the tracked
  /// `.gg/gg.json`: publish/merge progress lives in the git-ignored
  /// `.gg/gg-publish.json` now. They are pruned whenever a state is written.
  static const obsoleteKeys = [
    'doPrepareVersion',
    'doPublishPubDev',
    'doMerge',
    'doPublishGit',
    'doPublish',
  ];

  // ...........................................................................
  /// Returns previously set value
  Future<bool> readSuccess({
    required Directory directory,
    required String key,
    required GgLog ggLog,
    bool ignoreUnstaged = false,
  }) async {
    // Get the last changes hash
    final changesHash = await _lastChangesHash.get(
      directory: directory,
      ggLog: ggLog,
      ignoreFiles: ignoreFiles,
      ignoreUnstaged: ignoreUnstaged,
    );

    // If no config file exists, return false
    final fileExists = await File(
      _configFile(directory: directory).path,
    ).exists();

    if (!fileExists) {
      return false;
    }

    // Get the hash written to .gg/gg.json
    final hashInCheckJson = await DirectJson.readFile<int>(
      file: _configFile(directory: directory),
      path: _hashPath(key).join('/'),
    );

    // Compare the two hashes
    // If they are the same, return true.
    // If they are different, return false.
    return changesHash == hashInCheckJson;
  }

  // ...........................................................................
  /// Updates .gg/gg.json and writes the success state for this key.
  Future<void> writeSuccess({
    required Directory directory,
    required String key,
    bool ignoreUnstaged = false,
  }) async {
    // Nothing committed so far? Do nothing.
    await _checkCommitsAvailable(directory, ggLog);

    // If success is already written, return
    final isWritten = await readSuccess(
      directory: directory,
      key: key,
      ggLog: ggLog,
      ignoreUnstaged: ignoreUnstaged,
    );
    if (isWritten) {
      return;
    }

    // Ensure configuration directory exists before writing
    await _ensureConfigDirectoryExists(directory);

    // Prune keys of earlier gg versions; the pruning is committed together
    // with the hash written below.
    await _removeObsoleteKeys(directory);

    // Get the hash of the current commit
    final hash = await currentHash(
      directory: directory,
      ggLog: ggLog,
      ignoreUnstaged: ignoreUnstaged,
    );

    // Write the hash to .gg/gg.json
    await DirectJson.writeFile(
      file: _configFile(directory: directory),
      path: _hashPath(key).join('/'),
      value: hash,
    );

    // Ammend changes to .gg/gg.json
    await _commitOrAmmendStateChanges(directory);
  }

  // ...........................................................................
  /// Returns the current hash of the last changes
  Future<int> currentHash({
    required Directory directory,
    required GgLog ggLog,
    bool ignoreUnstaged = false,
  }) async {
    return await _lastChangesHash.get(
      directory: directory,
      ggLog: ggLog,
      ignoreFiles: ignoreFiles,
      ignoreUnstaged: ignoreUnstaged,
    );
  }

  // ...........................................................................
  /// Replaces the hash in .gg/gg.json with the current hash
  Future<void> updateHash({
    required int hash,
    required Directory directory,
  }) async {
    final current = await currentHash(directory: directory, ggLog: ggLog);
    if (current == hash) {
      return;
    }

    final ggJsonFile = _configFile(directory: directory);

    if (!await ggJsonFile.exists()) {
      return;
    }

    final ggJSonFileContent = (await ggJsonFile.readAsString()).replaceAll(
      '$hash',
      '$current',
    );
    await ggJsonFile.writeAsString(ggJSonFileContent);
  }

  // ...........................................................................
  /// Resets the success state
  Future<void> reset({required Directory directory}) async {
    await _ensureConfigDirectoryExists(directory);
    await _configFile(directory: directory).writeAsString('{}');
  }

  // ######################
  // Private
  // ######################

  final LastChangesHash _lastChangesHash;

  final IsPushed _isPushed;
  final ModifiedFiles _modifiedFiles;
  final Commit _commit;
  final HeadMessage _headMessage;
  final HasRemote _hasRemote;
  final CommitCount _commitCount;

  // ...........................................................................
  /// Directories already pruned in this process. writeSuccess runs on every
  /// check of every command — without the memo the migration read below
  /// would tax that hot path forever.
  static final Set<String> _prunedDirectories = {};

  // ...........................................................................
  /// Removes [obsoleteKeys] from `.gg/gg.json` when present. An empty file
  /// carries nothing to prune; other malformed files need no handling here:
  /// the preceding [readSuccess] rejects them.
  Future<void> _removeObsoleteKeys(Directory directory) async {
    if (!_prunedDirectories.add(directory.path)) {
      return;
    }
    final file = _configFile(directory: directory);
    if (!await file.exists()) {
      return;
    }
    final content = await file.readAsString();
    if (content.trim().isEmpty) {
      return;
    }
    final decoded = jsonDecode(content) as Map<String, dynamic>;
    if (!obsoleteKeys.any(decoded.containsKey)) {
      return;
    }
    obsoleteKeys.forEach(decoded.remove);
    await file.writeAsString(jsonEncode(decoded));
  }

  // ...........................................................................
  List<String> _hashPath(String name) => [name, 'success', 'hash'];

  // ...........................................................................
  /// Returns the configuration directory `.gg` inside the given [directory].
  Directory _configDirectory({required Directory directory}) {
    return Directory(join(directory.path, '.gg'));
  }

  // ...........................................................................
  /// Ensures that the configuration directory `.gg` exists.
  Future<void> _ensureConfigDirectoryExists(Directory directory) async {
    final dir = _configDirectory(directory: directory);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  // ...........................................................................
  /// Returns the configuration file `.gg/gg.json` inside the given
  /// [directory].
  ///
  /// The files inside `.gg` are no longer hidden. A checkout made before that
  /// change still carries the state under [legacyConfigFileName]; it is
  /// renamed on first access, so the recorded check results survive the
  /// upgrade instead of being silently recomputed.
  File _configFile({required Directory directory}) {
    final dir = _configDirectory(directory: directory);
    final file = File(join(dir.path, configFileName));
    final legacy = File(join(dir.path, legacyConfigFileName));

    if (!file.existsSync() && legacy.existsSync()) {
      legacy.renameSync(file.path);
    }

    return file;
  }

  // ...........................................................................
  Future<void> _commitOrAmmendStateChanges(Directory directory) async {
    // Check if only .gg/gg.json is currently changed
    final modifiedFiles = await _modifiedFiles.get(
      directory: directory,
      ggLog: ggLog,
    );

    // If nothing changed, return
    if (modifiedFiles.isEmpty) {
      return;
    }

    // The deleted legacy file is part of the set right after the migration in
    // _configFile — the rename must not stop the state commit.
    final onlyGgJsonChanged =
        modifiedFiles.isNotEmpty &&
        modifiedFiles.every(
          (p) =>
              p == '.gg/' ||
              p == '.gg/$configFileName' ||
              p == '.gg/$legacyConfigFileName',
        );

    // Remember if everything is committed and pushed
    final everythingWasCommitted = onlyGgJsonChanged;

    // If not everything was committed before, return here.
    //  gg.json will be committed with the next commit.
    if (!everythingWasCommitted) {
      return;
    }

    // ...................................
    // Otherwise commit or ammend .gg/gg.json

    // Check if the repository has a remote
    final hasRemote = await _hasRemote.get(directory: directory, ggLog: ggLog);

    final everythingWasPushed = hasRemote && await _wasPushed(directory);

    // ...........................
    // To have a clean git history,
    // we will ammend changes to .gg/gg.json to the last commit.
    // - If everything was committed and pushed, create a new commit
    // - If everything was committed but not pushed, ammend to last commit
    final message = everythingWasPushed
        ? '#gg: Add .gg/gg.json check results'
        : await _headMessage.get(
            directory: directory,
            ggLog: ggLog,
            throwIfNotEverythingIsCommitted: false,
          );

    await _commit.commit(
      directory: directory,
      ggLog: ggLog,
      doStage: true,
      message: message,
      ammend: !everythingWasPushed,
    );
  }

  // ...........................................................................
  Future<bool> _wasPushed(Directory directory) async {
    return await _isPushed.get(
      directory: directory,
      ggLog: (_) {},
      ignoreUnCommittedChanges: true,
    );
  }

  // ...........................................................................
  Future<void> _checkCommitsAvailable(Directory directory, GgLog ggLog) async {
    final commitCount = await _commitCount.get(
      directory: directory,
      ggLog: ggLog,
    );
    if (commitCount == 0) {
      throw Exception(
        cError('There must be at least one commit in the repository.'),
      );
    }
  }
}

/// Mock for [GgState]
class MockGgState extends MockDirCommand<void> implements GgState {}
