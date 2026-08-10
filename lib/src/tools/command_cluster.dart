// @license
// Copyright (c) 2019 - 2024 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one_core/src/tools/gg_state.dart';
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
    GgState? state,
  }) : _state = state ?? GgState(ggLog: ggLog) {
    _addArgs();
  }

  // ...........................................................................
  /// The short description printed at the beginning of each command
  final String shortDescription;

  /// The state key used to save the state of the command cluster
  final String stateKey;

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

    // Was successful before? Do nothing.
    if (!await _actionIsNeeded(directory, ggLog, force)) {
      _printAlreadyDoneSuccess(ggLog);
      return;
    }

    // Execute commands.
    try {
      for (final command in commands) {
        await command.exec(
          directory: directory,
          ggLog: ggLog,
          options: options,
        );
      }

      // Save success
      saveState ??= argResults?['save-state'] as bool? ?? true;
      if (saveState) {
        await _state.writeSuccess(directory: directory, key: stateKey);
      }
    } catch (e) {
      rethrow;
    }
  }

  /// The commands to run
  final List<DirCommand<void>> commands;

  // ######################
  // Private
  // ######################

  final GgState _state;

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
