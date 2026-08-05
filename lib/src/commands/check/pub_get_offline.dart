// @license
// Copyright (c) 2019 - 2024 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_is_flutter/gg_is_flutter.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart' as mocktail;
import 'package:path/path.dart' as p;

// #############################################################################

/// Runs `dart pub get --offline` (or the Flutter equivalent) so that
/// `pubspec.lock` matches `pubspec.yaml` before the other checks run.
class PubGetOffline extends DirCommand<void> {
  /// Constructor.
  PubGetOffline({
    required super.ggLog,
    GgProcessWrapper processWrapper = const GgProcessWrapper(),
  }) : _processWrapper = processWrapper,
       super(
         name: 'pub-get-offline',
         description: 'Sync the lock file with the manifest, offline',
       );

  final GgProcessWrapper _processWrapper;

  // ...........................................................................
  @override
  Future<void> get({required Directory directory, required GgLog ggLog}) async {
    if (!File(p.join(directory.path, 'pubspec.yaml')).existsSync()) {
      return;
    }

    final executable = isFlutterDir(directory) ? 'flutter' : 'dart';
    const args = ['pub', 'get', '--offline'];

    final statusPrinter = GgStatusPrinter<ProcessResult>(
      ggLog: ggLog,
      message: 'Running "$executable ${args.join(' ')}"',
      dark: true,
    );
    statusPrinter.logStatus(GgStatusPrinterStatus.running);

    final result = await _processWrapper.run(
      executable,
      args,
      workingDirectory: directory.path,
    );

    statusPrinter.logStatus(
      result.exitCode == 0
          ? GgStatusPrinterStatus.success
          : GgStatusPrinterStatus.error,
    );

    if (result.exitCode != 0) {
      throw Exception(
        cError('"$executable ${args.join(' ')}" failed: ${result.stderr}'),
      );
    }
  }
}

// .............................................................................
/// A mocktail mock.
class MockPubGetOffline extends mocktail.Mock implements PubGetOffline {}
