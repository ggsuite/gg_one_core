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
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart' as mocktail;

// #############################################################################

/// The npm scripts every TypeScript project must declare in its package.json.
const List<String> requiredNpmScripts = <String>['test', 'build', 'lint'];

/// The npm scripts required of a project that ships no TypeScript sources —
/// a hybrid without a `tsconfig.json`.
///
/// `build` and `lint` are TypeScript tooling: there is nothing to compile and
/// nothing for eslint to read. The tests remain required, because publishing
/// still has to run them.
const List<String> requiredNpmScriptsWithoutTypeScript = <String>['test'];

/// The publish-lifecycle script that must reach `build`. npm's modern name is
/// `prepublishOnly`; the deprecated `prepublish` is accepted as an equivalent.
/// Exactly one of these must be present (unless the package is private).
const List<String> prepublishScriptNames = <String>[
  'prepublishOnly',
  'prepublish',
];

/// The script that the `build` script must run, so the test suite always runs
/// as part of a build.
const String buildMustRunScript = 'test';

/// npm runs this script automatically right before `build`. Running the tests
/// there satisfies the `build` → `test` rule just as well.
const String buildPreScript = 'prebuild';

/// The script that the publish-lifecycle script must run, so a fresh build
/// (which in turn runs the tests) always precedes a publish.
const String prepublishMustRunScript = 'build';

/// Checks that a TypeScript project's `package.json` declares every npm script
/// gg relies on and wires them into the expected publish chain
/// (`prepublishOnly` → `build` → `test`):
///
/// * `test`, `build` and `lint` scripts must all be present — `build` and
///   `lint` only when the project carries a `tsconfig.json`. A hybrid without
///   one ships no TypeScript sources, so there is nothing to compile or lint
///   and only `test` is required.
/// * The `build` script must run `test`, so the tests always run as part of a
///   build. A `prebuild` script running `test` counts too, because npm runs it
///   right before `build`. Hybrids are exempt, as their build produces the
///   Dart and TypeScript artifacts and runs its tests separately.
/// * `prepublishOnly` (or the deprecated `prepublish`) must be present and
///   reach the tests — via `build` where there is one, directly otherwise.
///
/// Packages marked `"private": true` are never published and are therefore
/// exempt from the `prepublishOnly` requirement (the `build` → `test` rule
/// still applies to private pure-TypeScript packages).
///
/// Dart and Flutter projects are skipped. Cross-language bridge repos are
/// checked as TypeScript (see [checkProjectType]).
class CheckPackageJsonScripts extends DirCommand<void> {
  /// Constructor.
  CheckPackageJsonScripts({required super.ggLog})
    : super(
        name: 'package-json-scripts',
        description:
            "Checks that a TypeScript project's package.json declares all "
            'npm scripts required by gg.',
      );

  /// Example instance for tests — logs to `print`.
  factory CheckPackageJsonScripts.example() =>
      CheckPackageJsonScripts(ggLog: print);

  // ...........................................................................
  @override
  Future<void> get({required Directory directory, required GgLog ggLog}) async {
    await check(directory: directory);

    // Only TypeScript-treated projects (pure TypeScript repos and bridges)
    // carry a package.json with scripts.
    if (checkProjectType(directory) != ProjectType.typescript) {
      return;
    }

    final statusPrinter = GgStatusPrinter<void>(
      message: 'Checking package.json scripts',
      ggLog: ggLog,
    );
    statusPrinter.logStatus(GgStatusPrinterStatus.running);

    try {
      _check(directory);
      statusPrinter.logStatus(GgStatusPrinterStatus.success);
    } catch (_) {
      statusPrinter.logStatus(GgStatusPrinterStatus.error);
      rethrow;
    }
  }

  // ######################
  // Private
  // ######################

  // ...........................................................................
  void _check(Directory directory) {
    final scripts = readNpmScripts(directory);

    // Only a project that actually compiles TypeScript is held to the
    // TypeScript contract. A hybrid without a `tsconfig.json` reaches this
    // check because it carries a package.json, but it ships no sources to
    // build or lint. (A package.json without a pubspec.yaml and without a
    // tsconfig.json never gets here — checkProjectType reports it as none.)
    final compilesTypeScript = File(
      '${directory.path}/tsconfig.json',
    ).existsSync();
    final required = compilesTypeScript
        ? requiredNpmScripts
        : requiredNpmScriptsWithoutTypeScript;

    final missing = required
        .where((name) => !scripts.containsKey(name))
        .toList();
    if (missing.isNotEmpty) {
      throw Exception(
        cError(
          'package.json is missing required scripts: '
          '${missing.join(', ')}. This project must declare: '
          '${required.join(', ')} and one of '
          '${prepublishScriptNames.join(' / ')}.',
        ),
      );
    }

    // The `build` script must run `test`, so the tests always run as part of a
    // build — either directly or via `prebuild`, which npm executes right
    // before `build`. Hybrids are exempt: their build produces the Dart and
    // TypeScript artifacts and runs its tests separately. A project without
    // TypeScript declares no `build` at all, so there is nothing to check.
    final buildScript = scripts['build'];
    final preBuildScript = scripts[buildPreScript] ?? '';
    if (buildScript != null &&
        !isHybridProject(directory) &&
        !_referencesScript(buildScript, buildMustRunScript) &&
        !_referencesScript(preBuildScript, buildMustRunScript)) {
      throw Exception(
        cError(
          'The "build" script must run $buildMustRunScript, directly or via '
          '"$buildPreScript" (its command is "$buildScript").',
        ),
      );
    }

    // Private packages are never published (npm/pnpm refuse to publish them),
    // so they need no publish-lifecycle script.
    if (isPrivateNpmPackage(directory)) {
      return;
    }

    // One of `prepublishOnly` (preferred) / `prepublish` must be present …
    final prepublishName = prepublishScriptNames.firstWhere(
      scripts.containsKey,
      orElse: () => '',
    );
    // … and it must reach the tests: via `build` when the project has one,
    // directly otherwise. The point of the chain is that publishing never
    // skips the test suite, not that a `build` step exists.
    final mustRun = buildScript != null
        ? prepublishMustRunScript
        : buildMustRunScript;

    if (prepublishName.isEmpty) {
      throw Exception(
        cError(
          'package.json is missing a publish-lifecycle script. This project '
          'must declare one of: ${prepublishScriptNames.join(' / ')} '
          '(it must run $mustRun), or set "private": true.',
        ),
      );
    }

    final prepublish = scripts[prepublishName]!;
    if (!_referencesScript(prepublish, mustRun)) {
      throw Exception(
        cError(
          'The "$prepublishName" script must run $mustRun '
          '(its command is "$prepublish").',
        ),
      );
    }
  }

  // ...........................................................................
  /// Whether [command] invokes the npm script named [name], matched as a
  /// whole word so `test` does not match `latest`.
  bool _referencesScript(String command, String name) =>
      RegExp('\\b${RegExp.escape(name)}\\b').hasMatch(command);
}

// .............................................................................
/// A mocktail mock.
class MockCheckPackageJsonScripts extends mocktail.Mock
    implements CheckPackageJsonScripts {}
