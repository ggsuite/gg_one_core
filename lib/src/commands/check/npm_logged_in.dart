// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_lang/gg_lang.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_publish/gg_publish.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart' as mocktail;

// #############################################################################

/// Checks that the user is authenticated with the registry a TypeScript package
/// publishes to, before the package is published.
///
/// Without this check a missing or expired token surfaces only as a cryptic
/// `404 Not Found` in the middle of `pnpm publish` (npm masks an unauthorized
/// publish of a scoped package as a 404). Running `<pm> whoami` up front turns
/// that into an actionable "not logged in" error before anything is built or
/// versioned.
///
/// The check resolves the package's *actual* publish registry — rather than
/// assuming npmjs.org — so it also works for Azure DevOps, GitHub Packages and
/// other private registries. The resolution lives in gg_lang's
/// [NpmRegistryResolver], which the publish flow uses as well.
///
/// `whoami` is then run against that registry. A failure is only treated as a
/// hard error when the output clearly indicates an authentication problem
/// (401/403/ENEEDAUTH/…); otherwise the registry likely does not support
/// `whoami` (common for private feeds) and the check skips instead of
/// false-failing — the auth is verified for real at publish time.
///
/// It runs in the package's own directory, and a failure **measures** why:
/// a `packageManager` field in `package.json` makes that exact version serve
/// the package while a shell anywhere else starts the globally installed one,
/// and the major versions do not share a credential store. So the failure
/// asks the package manager for its version here and in a directory that
/// pins nothing, and when the two majors differ it says so with both
/// numbers — plus, when plain `npm` *is* authenticated, where the token
/// actually went. A `<pm> login` that reported success while this check
/// keeps failing has no other explanation, and an error that names it is one
/// the user can act on instead of retrying unchanged.
///
/// The check applies to every package that publishes to npm — including a
/// hybrid, whose `pubspec.yaml` does not exempt it from needing npm
/// credentials. Packages that publish nowhere or to pub.dev only are skipped.
class NpmLoggedIn extends DirCommand<void> {
  /// Constructor.
  NpmLoggedIn({
    required super.ggLog,
    this.processWrapper = const GgProcessWrapper(),
    PublishTo? publishTo,
    NpmRegistryResolver? registryResolver,
  }) : _publishTo = publishTo ?? PublishTo(ggLog: ggLog),
       _registryResolver =
           registryResolver ??
           NpmRegistryResolver(processWrapper: processWrapper),
       super(
         name: 'npm-logged-in',
         description:
             'Checks that the user is authenticated with the npm registry.',
       );

  /// Example instance for tests — logs to `print`.
  factory NpmLoggedIn.example() => NpmLoggedIn(ggLog: print);

  /// The process wrapper used to execute shell processes.
  final GgProcessWrapper processWrapper;

  // ...........................................................................
  @override
  Future<void> get({required Directory directory, required GgLog ggLog}) async {
    await check(directory: directory);

    // Only npm-published packages need npm authentication. pub.dev-only and
    // private packages are unaffected.
    final targets = await _publishTo.targets(directory);
    if (!targets.contains(PublishTarget.npm)) {
      GgStatusPrinter<void>(
        ggLog: ggLog,
        message: 'Skipping npm auth check (${targets.label} target)',
        dark: true,
      ).logStatus(GgStatusPrinterStatus.success);
      return;
    }

    final pm = detectTypeScriptPackageManager(directory);
    final registry = await _registryResolver.registryOf(
      directory: directory,
      packageManager: pm,
    );
    final registryLabel = registry ?? 'the npm registry';

    final statusPrinter = GgStatusPrinter<void>(
      ggLog: ggLog,
      message: 'Logged in to $registryLabel',
    );
    statusPrinter.logStatus(GgStatusPrinterStatus.running);

    // npm/pnpm/yarn are shell shims (pnpm.cmd on Windows, a PATH script on
    // Linux/macOS), so run through a shell — otherwise Windows cannot find the
    // executable and Process.run throws "cannot find the file".
    final result = await processWrapper.run(
      pm.executable,
      <String>['whoami', if (registry != null) '--registry=$registry'],
      workingDirectory: directory.path,
      runInShell: true,
    );

    if (result.exitCode == 0) {
      statusPrinter.logStatus(GgStatusPrinterStatus.success);
      return;
    }

    // `whoami` reports failures on stderr, but fall back to stdout so the cause
    // is never swallowed.
    final err = result.stderr.toString().trim();
    final out = result.stdout.toString().trim();
    final detail = err.isNotEmpty ? err : out;

    // A non-zero exit is ambiguous: the user may be logged out, or the registry
    // may simply not support `whoami` (common for Azure DevOps / private
    // feeds). Only fail hard on a clear auth problem; otherwise skip.
    if (_looksLikeAuthFailure(detail)) {
      statusPrinter.logStatus(GgStatusPrinterStatus.error);
      throw Exception(
        cError(
          await _notLoggedInMessage(
            directory: directory,
            pm: pm,
            registry: registry,
            registryLabel: registryLabel,
            detail: detail,
          ),
        ),
      );
    }

    // Registry does not support `whoami` (or another non-auth error) — do not
    // block; the auth is verified at publish time.
    statusPrinter.logStatus(GgStatusPrinterStatus.success);
    // ggLog(
    //   yellow(
    //     'Could not verify auth for $registryLabel '
    //     '(${pm.executable} whoami: $detail); '
    //     'it is verified at publish time.',
    //   ),
    // );
  }

  // ######################
  // Private
  // ######################

  final PublishTo _publishTo;
  final NpmRegistryResolver _registryResolver;

  // ...........................................................................
  /// Builds the »not logged in« message for [registryLabel], naming the cause
  /// when the package manager is split across two major versions.
  ///
  /// A `packageManager` field in `package.json` makes the package manager
  /// serve exactly that version inside the package, while a shell anywhere
  /// else starts the globally installed one. The majors do **not** share a
  /// credential store, so a login that reported success can be invisible
  /// here — which is what »I did log in« means when this check still fails.
  /// Saying so, with both version numbers, is the difference between an
  /// error the user can act on and one they retry unchanged.
  Future<String> _notLoggedInMessage({
    required Directory directory,
    required TypeScriptPackageManager pm,
    required String? registry,
    required String registryLabel,
    required String detail,
  }) async {
    final loginRegistry = registry == null ? '' : ' --registry=$registry';
    final login = '"${pm.executable} login$loginRegistry"';

    final buffer = StringBuffer(
      'Not logged in to $registryLabel '
      '(${pm.executable} whoami failed: $detail). ',
    );

    final here = await _versionOf(pm, directory.path);
    final elsewhere = await _versionOf(pm, _neutralDirectory);
    final split =
        here != null && elsewhere != null && _major(here) != _major(elsewhere);

    if (!split) {
      buffer.write(
        'Run $login in ${directory.path} — there and not somewhere else: a '
        '"packageManager" field in package.json makes a different '
        '${pm.executable} version serve each directory, and the major '
        'versions do not share a credential store.',
      );
      return buffer.toString();
    }

    buffer.write(
      'In ${directory.path} ${pm.executable} $here runs, while a shell '
      'anywhere else starts ${pm.executable} $elsewhere — that is a '
      '"packageManager" field pinning the version per directory. The two '
      'majors keep their credentials in different files, so a login run '
      'outside this directory never reaches this check, however successful '
      'it looked. ',
    );

    if (await _npmIsAuthenticated(directory: directory, registry: registry)) {
      buffer.write(
        'npm itself is authenticated for $registryLabel, which says where '
        'the token went: it is in the npm configuration, and ${pm.executable} '
        '$here does not read it. ',
      );
    }

    buffer.write(
      'Run $login in ${directory.path}, or lift the global ${pm.executable} '
      'onto the pinned version with "corepack prepare ${pm.executable}@$here '
      '--activate" and log in again.',
    );

    return buffer.toString();
  }

  /// A directory that carries no `package.json`, so a package manager started
  /// in it reports the globally installed version rather than a pinned one.
  static final String _neutralDirectory = Directory.systemTemp.path;

  // ...........................................................................
  /// The version [pm] reports in [workingDirectory], or null when it cannot
  /// be determined.
  ///
  /// The output is searched for the version rather than trimmed: pnpm 11
  /// delegates several commands to npm, whose deprecation warnings then share
  /// the stream with the answer.
  Future<String?> _versionOf(
    TypeScriptPackageManager pm,
    String workingDirectory,
  ) async {
    try {
      final result = await processWrapper.run(
        pm.executable,
        const <String>['--version'],
        workingDirectory: workingDirectory,
        runInShell: true,
      );
      if (result.exitCode != 0) return null;

      final match = _versionPattern.firstMatch('${result.stdout}');
      return match?.group(0);
    } on Object {
      // A package manager that cannot be started tells us nothing about the
      // login — fall back to the generic message.
      return null;
    }
  }

  /// Whether plain `npm` is authenticated for [registry].
  ///
  /// npm reads the npm configuration no matter which package manager the
  /// package pins, so a yes here pinpoints the split: the credentials exist,
  /// they are just not where the pinned package manager looks.
  Future<bool> _npmIsAuthenticated({
    required Directory directory,
    required String? registry,
  }) async {
    try {
      final result = await processWrapper.run(
        'npm',
        <String>['whoami', if (registry != null) '--registry=$registry'],
        workingDirectory: directory.path,
        runInShell: true,
      );
      return result.exitCode == 0;
    } on Object {
      return false;
    }
  }

  /// Matches a semantic version anywhere in a command's output.
  static final RegExp _versionPattern = RegExp(r'\d+\.\d+\.\d+');

  /// The major of the version [version].
  static String _major(String version) => version.split('.').first;

  // ...........................................................................
  /// Whether [detail] clearly indicates an authentication failure (as opposed
  /// to the registry simply not supporting `whoami`).
  static bool _looksLikeAuthFailure(String detail) {
    final text = detail.toLowerCase();
    return text.contains('401') ||
        text.contains('403') ||
        text.contains('eneedauth') ||
        text.contains('unauthor') ||
        text.contains('forbidden') ||
        text.contains('authentication') ||
        text.contains('not logged in') ||
        text.contains('log in first');
  }
}

// .............................................................................
/// A mocktail mock.
class MockNpmLoggedIn extends mocktail.Mock implements NpmLoggedIn {}
