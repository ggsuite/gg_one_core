// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_one_core/src/tools/gg_rc.dart';
import 'package:gg_one_core/src/tools/gg_state.dart';
import 'package:gg_one_core/src/tools/repo_lock.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_status_printer/gg_status_printer.dart';

/// A cluster of commands that is run in sequence
class CommandCluster extends DirCommand<void> {
  /// Constructor
  CommandCluster({
    required super.ggLog,
    required this.commands,
    required super.name,
    required super.description,
    required this.stateKey,
    required this.shortDescription,
    this.checksSetting,
    GgState? state,
    RepoLock? repoLock,
  }) : _state = state ?? GgState(ggLog: ggLog),
       _repoLock = repoLock ?? RepoLock() {
    _addArgs();
  }

  // ...........................................................................
  /// The short description printed at the beginning of each command
  final String shortDescription;

  /// The state key used to save the state of the command cluster
  final String stateKey;

  /// The repository setting that can switch the commands off, e.g.
  /// [GgRc.commitChecks]. When it is `false` in the repository's
  /// `.gg/gg_rc`, the commands are skipped and success is recorded right
  /// away. Null: the commands always run.
  final List<String>? checksSetting;

  // ...........................................................................
  @override
  Future<void> exec({
    required Directory directory,
    required GgLog ggLog,
    bool? force,
    bool? saveState,
    Map<String, dynamic> options = const {},
  }) => get(
    directory: directory,
    ggLog: ggLog,
    force: force,
    saveState: saveState,
    options: options,
  );

  // ...........................................................................
  @override
  Future<void> get({
    required Directory directory,
    required GgLog ggLog,
    bool? force,
    bool? saveState,
    Map<String, dynamic> options = const {},
  }) async {
    // If we have no commands, let's do nothing.
    if (commands.isEmpty) {
      return;
    }

    // Switched off in the repository's .gg/gg_rc? Record success without
    // running anything.
    final setting = checksSetting;
    if (setting != null && !GgRc.loadRepo(directory).flag(setting)) {
      ggLog(
        cDetail(
          '$shortDescription skipped: '
          '${GgRc.keyPath(setting)} is false in .gg/${GgRc.repoFileName}.',
        ),
      );
      await _repoLock.use(
        directory: directory,
        ggLog: ggLog,
        body: (_) => _state.writeSuccess(directory: directory, key: stateKey),
      );
      return;
    }

    // Was successful before? Do nothing.
    if (!await _actionIsNeeded(directory, ggLog, force)) {
      _printAlreadyDoneSuccess(ggLog);
      return;
    }

    // One gg run at a time works in a repository. The commands write into
    // it — coverage, generated files, the state — and two runs side by side
    // spoil each other's results.
    await _repoLock.use(
      directory: directory,
      ggLog: ggLog,
      body: (waited) async {
        // The run this one waited for may have checked this very state:
        // its result is as good as an own one.
        if (waited && !await _actionIsNeeded(directory, ggLog, force)) {
          _printAlreadyDoneSuccess(ggLog);
          return;
        }

        // Execute commands.
        for (final command in commands) {
          await command.exec(
            directory: directory,
            ggLog: ggLog,
            options: options,
          );
        }

        // Save success. Shielded: the checks passed, and a caller that
        // cancels its process scope now must not stop the state between the
        // file and its commit.
        saveState ??= argResults?['save-state'] as bool? ?? true;
        if (saveState!) {
          await GgProcessScope.shield(
            () => _state.writeSuccess(directory: directory, key: stateKey),
          );
        }
      },
    );
  }

  /// The commands to run
  final List<DirCommand<void>> commands;

  // ######################
  // Private
  // ######################

  final GgState _state;

  /// Makes a second gg run in the same repository wait for the first.
  final RepoLock _repoLock;

  // ...........................................................................
  void _addArgs() {
    argParser.addFlag(
      'force',
      abbr: 'f',
      negatable: false,
      help: 'Executes the commands also if they were successful before.',
      defaultsTo: false,
    );

    argParser.addFlag(
      'save-state',
      abbr: 's',
      negatable: true,
      help: 'Saves success state for later reuse.',
      defaultsTo: true,
    );
  }

  // ...........................................................................
  Future<bool> _wasSuccessfulBefore(Directory directory, GgLog ggLog) async {
    return await _state.readSuccess(
      directory: directory,
      key: stateKey,
      ggLog: ggLog,
    );
  }

  // ...........................................................................
  Future<bool> _actionIsNeeded(
    Directory directory,
    GgLog ggLog,
    bool? force,
  ) async {
    force = force ?? argResults?['force'] as bool? ?? false;
    final needsAction =
        force || !(await _wasSuccessfulBefore(directory, ggLog));
    return needsAction;
  }

  // ...........................................................................
  void _printAlreadyDoneSuccess(GgLog ggLog) {
    GgStatusPrinter<void>(
      message: shortDescription,
      ggLog: ggLog,
      useCarriageReturn: false,
      dark: true,
    ).logStatus(GgStatusPrinterStatus.success);
  }
}
