// @license
// Copyright (c) 2019 - 2024 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_is_github/gg_is_github.dart';
import 'package:gg_lang/gg_lang.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:gg_test/gg_test.dart';
import 'package:mocktail/mocktail.dart' as mocktail;

// #############################################################################

/// Applies formatting rules to a project's source code.
///
/// Implementations own the entire format lifecycle: invoking the underlying
/// tool, rendering progress via [GgStatusPrinter], and throwing an
/// [Exception] on failure.
abstract class Formatter {
  /// Constructor.
  const Formatter();

  /// Runs the formatter against [directory]. Throws on failure.
  Future<void> run({required Directory directory, required GgLog ggLog});
}

// #############################################################################

/// Runs `dart format` on a Dart or Flutter package.
class DartFormatter extends Formatter {
  /// Constructor.
  const DartFormatter({
    this.processWrapper = const GgProcessWrapper(),
    bool Function()? isGitHub,
    this.catalog,
  }) : _isGitHubImpl = isGitHub;

  /// Example instance for tests — uses the real default process wrapper.
  factory DartFormatter.example() => const DartFormatter();

  /// The process wrapper used to execute shell processes.
  final GgProcessWrapper processWrapper;

  /// The language catalog. Defaults to the bundled gg_lang catalog when null.
  final LanguageCatalog? catalog;

  final bool Function()? _isGitHubImpl;
  bool get _isGitHub => _isGitHubImpl != null ? _isGitHubImpl() : isGitHub;

  @override
  Future<void> run({required Directory directory, required GgLog ggLog}) async {
    final cat = catalog ?? await LanguageCatalog.load();
    final command = cat.spec(ProjectType.dart).command('formatFix');

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

    if (result.exitCode == 0) {
      statusPrinter.logStatus(GgStatusPrinterStatus.success);
      return;
    }

    final std = '${result.stderr as String}\n${result.stdout as String}';
    final files = ErrorInfoReader().filePathes(std);

    // On GitHub runners, fail the build when formatting would have changed
    // files and list the culprits. Locally, `dart format` already rewrote
    // the files in-place, so the run is considered successful.
    if (_isGitHub && files.isNotEmpty) {
      statusPrinter.logStatus(GgStatusPrinterStatus.error);
      ggLog(cDetail('The following files were formatted:'));
      ggLog(files.map((e) => '- ${cError(e)}').join('\n'));
      throw Exception(cError('dart format failed.'));
    }

    if (files.isEmpty) {
      statusPrinter.logStatus(GgStatusPrinterStatus.error);
      ggLog(brightBlack('std'));
      throw Exception(cError('dart format failed.'));
    }

    statusPrinter.logStatus(GgStatusPrinterStatus.success);
  }
}

// #############################################################################

/// Formats a TypeScript project — but only when the project opts in.
///
/// When the project's `package.json` declares the matching script, that
/// script is run (`<pm> run format` locally, `<pm> run format:check` on
/// GitHub runners) so each repo controls its own formatting. When no such
/// script exists, formatting is skipped — gg never invokes `eslint` (or any
/// other tool) directly. TypeScript linting is driven by the project's
/// `lint` script in the analyze step instead.
class TypeScriptFormatter extends Formatter {
  /// Constructor.
  const TypeScriptFormatter({
    this.processWrapper = const GgProcessWrapper(),
    bool Function()? isGitHub,
    TypeScriptPackageManager Function(Directory)? packageManager,
  }) : _isGitHubImpl = isGitHub,
       _packageManager = packageManager;

  /// Example instance for tests — uses the real default process wrapper and
  /// package-manager detection.
  factory TypeScriptFormatter.example() => const TypeScriptFormatter();

  /// The process wrapper used to execute shell processes.
  final GgProcessWrapper processWrapper;

  final bool Function()? _isGitHubImpl;
  bool get _isGitHub => _isGitHubImpl != null ? _isGitHubImpl() : isGitHub;

  final TypeScriptPackageManager Function(Directory)? _packageManager;

  @override
  Future<void> run({required Directory directory, required GgLog ggLog}) async {
    // On GitHub runners check only (`format:check`); locally auto-fix
    // (`format`).
    final scriptName = _isGitHub ? 'format:check' : 'format';

    // No `format`/`format:check` script → nothing to format. gg never calls
    // `eslint` directly; TypeScript style is enforced by the `lint` script in
    // the analyze step.
    if (!hasNpmScript(directory, scriptName)) {
      GgStatusPrinter<void>(
        ggLog: ggLog,
        message: 'No "$scriptName" script — skipping TypeScript formatting',
        dark: true,
      ).logStatus(GgStatusPrinterStatus.success);
      return;
    }

    final pm = (_packageManager ?? detectTypeScriptPackageManager).call(
      directory,
    );
    final cmd = pm.runCommand(scriptName);
    final label = '${cmd.executable} ${cmd.args.join(' ')}';

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
      runInShell: true,
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

    throw Exception(cError('Format check failed ("$label").'));
  }
}

// .............................................................................
/// A mocktail mock.
class MockFormatter extends mocktail.Mock implements Formatter {}
