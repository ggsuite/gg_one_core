// @license
// Copyright (c) 2019 - 2024 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_lang/gg_lang.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:gg_test/gg_test.dart';
import 'package:mocktail/mocktail.dart' as mocktail;

// #############################################################################

/// Runs static analysis for a specific project type.
///
/// Implementations own the entire analysis lifecycle: invoking the underlying
/// tool, rendering progress via [GgStatusPrinter], parsing error output, and
/// throwing an [Exception] with a helpful message on failure.
abstract class Analyzer {
  /// Constructor.
  const Analyzer();

  /// Runs the analyzer against [directory]. Throws on failure.
  Future<void> run({required Directory directory, required GgLog ggLog});
}

// #############################################################################

/// Runs the catalog `analyze` command on a Dart or Flutter package.
class DartAnalyzer extends Analyzer {
  /// Constructor.
  const DartAnalyzer({
    this.processWrapper = const GgProcessWrapper(),
    this.catalog,
  });

  /// Example instance for tests — uses the real default process wrapper.
  factory DartAnalyzer.example() => const DartAnalyzer();

  /// The process wrapper used to execute shell processes.
  final GgProcessWrapper processWrapper;

  /// The language catalog. Defaults to the bundled gg_lang catalog when null.
  final LanguageCatalog? catalog;

  @override
  Future<void> run({required Directory directory, required GgLog ggLog}) async {
    final cat = catalog ?? await LanguageCatalog.load();
    final command = cat.spec(ProjectType.dart).command('analyze');

    final statusPrinter = GgStatusPrinter<ProcessResult>(
      ggLog: ggLog,
      message: 'Running "${command.label}"',
      dark: true,
    );
    statusPrinter.logStatus(GgStatusPrinterStatus.running);

    final result = await processWrapper.run(
      command.exec!,
      command.args,
      workingDirectory: directory.path,
    );

    statusPrinter.logStatus(
      result.exitCode == 0
          ? GgStatusPrinterStatus.success
          : GgStatusPrinterStatus.error,
    );

    if (result.exitCode == 0) {
      return;
    }

    final files = [
      ...ErrorInfoReader().filePathes(result.stderr as String),
      ...ErrorInfoReader().filePathes(result.stdout as String),
    ];
    ggLog('There are analyzer errors:');
    ggLog(files.map((e) => cError('- $e')).join('\n'));

    throw Exception(
      cError('Analyze failed. Run "${cCmd(command.label)}" to see details.'),
    );
  }
}

// #############################################################################

/// Runs TypeScript static analysis.
///
/// When the project's `package.json` declares a `lint` script, that script is
/// run (`<pm> run lint`) so each repo controls exactly what its analyze phase
/// does. Otherwise it falls back to the catalog default (`tsc --noEmit`) —
/// but only for projects that actually carry a `tsconfig.json`.
///
/// A hybrid without one ships no TypeScript sources at all: its `package.json`
/// exists to publish a payload to npm, not to compile anything. Falling back
/// to `tsc` there would demand a `typescript` devDependency for a compiler
/// that has nothing to read, so the analysis is skipped instead.
class TypeScriptAnalyzer extends Analyzer {
  /// Constructor.
  const TypeScriptAnalyzer({
    this.processWrapper = const GgProcessWrapper(),
    TypeScriptPackageManager Function(Directory)? packageManager,
    this.catalog,
  }) : _packageManager = packageManager;

  /// Example instance for tests — uses the real default process wrapper and
  /// package-manager detection.
  factory TypeScriptAnalyzer.example() => const TypeScriptAnalyzer();

  /// The process wrapper used to execute shell processes.
  final GgProcessWrapper processWrapper;

  /// The language catalog. Defaults to the bundled gg_lang catalog when null.
  final LanguageCatalog? catalog;

  final TypeScriptPackageManager Function(Directory)? _packageManager;

  @override
  Future<void> run({required Directory directory, required GgLog ggLog}) async {
    final pm = (_packageManager ?? detectTypeScriptPackageManager).call(
      directory,
    );

    final ({String executable, List<String> args}) cmd;
    final String label;
    final bool runInShell;

    if (hasNpmScript(directory, 'lint')) {
      // Prefer the project's own lint script when one is defined.
      cmd = pm.runCommand('lint');
      label = '${cmd.executable} ${cmd.args.join(' ')}';
      runInShell = true;
    } else if (!File('${directory.path}/tsconfig.json').existsSync()) {
      // No lint script and no TypeScript config — nothing for the compiler
      // to read. See the class doc.
      GgStatusPrinter<void>(
        ggLog: ggLog,
        message: 'Skipping TypeScript analysis (no lint script, no tsconfig)',
        dark: true,
      ).logStatus(GgStatusPrinterStatus.success);
      return;
    } else {
      final cat = catalog ?? await LanguageCatalog.load();
      final command = cat.spec(ProjectType.typescript).command('analyze');
      cmd = pm.execCommand(command.tool!, command.args);
      label = command.label;
      runInShell = command.runInShell;
    }

    final statusPrinter = GgStatusPrinter<ProcessResult>(
      ggLog: ggLog,
      message: 'Running "$label"',
      dark: true,
    );
    statusPrinter.logStatus(GgStatusPrinterStatus.running);

    final result = await processWrapper.run(
      cmd.executable,
      cmd.args,
      workingDirectory: directory.path,
      // Node tooling ships as `.cmd`/`.ps1` launchers on Windows, which
      // `dart:io` can only resolve via the shell.
      runInShell: runInShell,
    );

    statusPrinter.logStatus(
      result.exitCode == 0
          ? GgStatusPrinterStatus.success
          : GgStatusPrinterStatus.error,
    );

    if (result.exitCode == 0) {
      return;
    }

    final stdout = result.stdout as String;
    final stderr = result.stderr as String;
    if (stdout.isNotEmpty) ggLog(stdout.trimRight());
    if (stderr.isNotEmpty) ggLog(stderr.trimRight());

    throw Exception(
      cError(
        'TypeScript analysis failed. '
        'Run "${cCmd('${cmd.executable} ${cmd.args.join(' ')}')}" '
        'to see details.',
      ),
    );
  }
}

// .............................................................................
/// A mocktail mock.
class MockAnalyzer extends mocktail.Mock implements Analyzer {}
