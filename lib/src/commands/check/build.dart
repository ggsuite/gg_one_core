// @license
// Copyright (c) 2019 - 2024 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_lang/gg_lang.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart' as mocktail;

// #############################################################################

/// Builds a cross-language *bridge* repo before the other checks run.
///
/// A bridge ships a Dart manifest (`pubspec.yaml`) alongside a TypeScript
/// manifest (`package.json` + `tsconfig.json`); its Dart side and its tests
/// consume the compiled TypeScript output (`dist/`), which a fresh checkout
/// does not contain yet. So `gg can commit` always runs the project's
/// `build` script (`<pm> run build`, via the detected package manager) for
/// bridge repos.
///
/// Pure Dart, Flutter and pure TypeScript projects are left untouched: a pure
/// TypeScript repo builds as part of its own `test` script (see
/// `CheckPackageJsonScripts`), and Dart/Flutter projects have nothing to
/// build here.
class Build extends DirCommand<void> {
  /// Constructor.
  Build({
    required super.ggLog,
    GgProcessWrapper processWrapper = const GgProcessWrapper(),
  }) : _processWrapper = processWrapper,
       super(
         name: 'build',
         description: 'Build a bridge repo via its package.json script',
       );

  /// Example instance for tests — logs to `print`.
  factory Build.example() => Build(ggLog: print);

  final GgProcessWrapper _processWrapper;

  // ...........................................................................
  @override
  Future<void> get({required Directory directory, required GgLog ggLog}) async {
    await check(directory: directory);

    // Only bridge repos need an explicit build step before the other checks.
    if (!isBridgeProject(directory)) {
      return;
    }

    // Nothing to build when the project declares no `build` script.
    if (!hasNpmScript(directory, 'build')) {
      return;
    }

    final pm = detectTypeScriptPackageManager(directory);
    final cmd = pm.runCommand('build');
    final label = '${cmd.executable} ${cmd.args.join(' ')}';

    final statusPrinter = GgStatusPrinter<void>(
      message: 'Running "$label"',
      ggLog: ggLog,
      dark: true,
    );
    statusPrinter.logStatus(GgStatusPrinterStatus.running);

    final result = await _processWrapper.run(
      cmd.executable,
      cmd.args,
      workingDirectory: directory.path,
      // Node tooling ships as `.cmd`/`.ps1` launchers on Windows, which
      // `dart:io` can only resolve via the shell.
      runInShell: true,
    );

    statusPrinter.logStatus(
      result.exitCode == 0
          ? GgStatusPrinterStatus.success
          : GgStatusPrinterStatus.error,
    );

    if (result.exitCode != 0) {
      final stdout = result.stdout.toString();
      final stderr = result.stderr.toString();
      if (stdout.isNotEmpty) ggLog(stdout.trimRight());
      if (stderr.isNotEmpty) ggLog(stderr.trimRight());
      throw Exception(
        cError('"$label" failed with exit code ${result.exitCode}.'),
      );
    }
  }
}

// .............................................................................
/// A mocktail mock.
class MockBuild extends mocktail.Mock implements Build {}
