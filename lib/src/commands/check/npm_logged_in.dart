// @license
// Copyright (c) 2019 - 2024 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_lang/gg_lang.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_publish/gg_publish.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart' as mocktail;
import 'package:path/path.dart' as p;

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
/// other private registries. Resolution order:
/// 1. `publishConfig.registry` in `package.json`,
/// 2. the package scope's registry (`@scope:registry`) from the merged
///    `.npmrc`,
/// 3. the default `registry` from the merged `.npmrc`.
///
/// `whoami` is then run against that registry. A failure is only treated as a
/// hard error when the output clearly indicates an authentication problem
/// (401/403/ENEEDAUTH/…); otherwise the registry likely does not support
/// `whoami` (common for private feeds) and the check skips instead of
/// false-failing — the auth is verified for real at publish time.
///
/// The check only applies to packages whose publish target is `npm` (see
/// [PublishTo]). Dart/Flutter (`pub.dev`) and private (`none`) packages are
/// skipped.
class NpmLoggedIn extends DirCommand<void> {
  /// Constructor.
  NpmLoggedIn({
    required super.ggLog,
    this.processWrapper = const GgProcessWrapper(),
    PublishTo? publishTo,
  }) : _publishTo = publishTo ?? PublishTo(ggLog: ggLog),
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

    // Only npm-published packages need npm authentication. `pub.dev` (Dart)
    // and `none` (private) targets are unaffected.
    final target = await _publishTo.fromDirectory(directory);
    if (target != 'npm') {
      GgStatusPrinter<void>(
        ggLog: ggLog,
        message: 'Skipping npm auth check ($target target)',
        dark: true,
      ).logStatus(GgStatusPrinterStatus.success);
      return;
    }

    final pm = detectTypeScriptPackageManager(directory);
    final registry = await _resolveRegistry(directory: directory, pm: pm);
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
      final loginRegistry = registry == null ? '' : ' --registry=$registry';
      throw Exception(
        cError(
          'Not logged in to $registryLabel '
          '(${pm.executable} whoami failed: $detail). '
          'Run "${pm.executable} login$loginRegistry" or set a valid token in '
          '~/.npmrc before publishing.',
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

  // ...........................................................................
  /// Resolves the registry the package publishes to, mirroring how npm/pnpm
  /// pick it: `publishConfig.registry` → the scope's `@scope:registry` →
  /// the default `registry`. Returns null when none is configured (the package
  /// manager then uses its built-in default).
  Future<String?> _resolveRegistry({
    required Directory directory,
    required TypeScriptPackageManager pm,
  }) async {
    final pkg = _readPackageJson(directory);

    final publishConfig = pkg?['publishConfig'];
    if (publishConfig is Map) {
      final registry = publishConfig['registry'];
      if (registry is String && registry.isNotEmpty) {
        return registry;
      }
    }

    final name = pkg?['name'];
    if (name is String && name.startsWith('@') && name.contains('/')) {
      final scope = name.substring(0, name.indexOf('/'));
      final scoped = await _npmConfig(
        directory: directory,
        pm: pm,
        key: '$scope:registry',
      );
      if (scoped != null) {
        return scoped;
      }
    }

    return _npmConfig(directory: directory, pm: pm, key: 'registry');
  }

  // ...........................................................................
  /// Reads and parses `package.json`, or null when absent/unparseable.
  Map<String, dynamic>? _readPackageJson(Directory directory) {
    final file = File(p.join(directory.path, 'package.json'));
    if (!file.existsSync()) {
      return null;
    }
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  // ...........................................................................
  /// Reads a config value (e.g. `registry`, `@scope:registry`) from the merged
  /// `.npmrc` via `<pm> config get <key>`. Returns null when unset.
  Future<String?> _npmConfig({
    required Directory directory,
    required TypeScriptPackageManager pm,
    required String key,
  }) async {
    final result = await processWrapper.run(
      pm.executable,
      <String>['config', 'get', key],
      workingDirectory: directory.path,
      runInShell: true,
    );
    if (result.exitCode != 0) {
      return null;
    }
    final value = result.stdout.toString().trim();
    if (value.isEmpty || value == 'undefined' || value == 'null') {
      return null;
    }
    return value;
  }

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
