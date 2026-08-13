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
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart' as mocktail;
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

// #############################################################################

/// Checks that the package has no `pubspec_overrides.yaml` redirecting a
/// dependency to a local path.
///
/// A `path` override (written by `gg_localize_refs` / a multi-repo workspace)
/// resolves the package against the developer's working copies instead of the
/// versions on pub.dev — the upload succeeds but the published package is not
/// reproducible. Such a file must therefore be gone before publishing.
///
/// A `git` override is a different story: `gg do review` pins every repository
/// of a ticket to its feature branch that way, so the repositories are reviewed
/// against each other. That ref resolves for everybody, and `do publish`
/// removes the file before the upload anyway — so it does not block a publish.
///
/// The check only applies to Dart/Flutter packages; other project types have no
/// such file.
class NoPubspecOverrides extends DirCommand<void> {
  /// Constructor.
  NoPubspecOverrides({required super.ggLog})
    : super(
        name: 'no-pubspec-overrides',
        description: 'Checks that no pubspec_overrides.yaml exists.',
      );

  /// Example instance for tests — logs to `print`.
  factory NoPubspecOverrides.example() => NoPubspecOverrides(ggLog: print);

  /// The name of the file that must not exist when publishing.
  static const String fileName = 'pubspec_overrides.yaml';

  // ...........................................................................
  /// Whether [directory] currently has *effective* localized references — a
  /// [fileName] that really redirects at least one dependency to a local
  /// working copy.
  ///
  /// A missing file, an empty one, one whose `dependency_overrides` mapping is
  /// empty and one that only pins git refs all count as »no localized refs«:
  /// none of them makes the package resolve against something that exists on
  /// this machine only. An unparsable file counts as localized — it cannot
  /// prove the opposite, and the callers use this to *refuse* an operation.
  ///
  /// Used by `gg do merge`, which may only merge a ticket into the main branch
  /// when no repository still points at a working copy.
  static bool hasLocalizedRefs(Directory directory) {
    final file = File(p.join(directory.path, fileName));
    if (!file.existsSync()) {
      return false;
    }

    final content = file.readAsStringSync();
    if (content.trim().isEmpty) {
      return false;
    }

    final dynamic parsed;
    try {
      parsed = loadYaml(content);
    } catch (_) {
      return true;
    }

    if (parsed is! Map) {
      return false;
    }

    final overrides = parsed['dependency_overrides'];
    if (overrides == null) {
      return false;
    }
    if (overrides is! Map) {
      return true;
    }

    return overrides.values.any(_isPathOverride);
  }

  /// Whether [override] redirects a dependency to a local working copy.
  ///
  /// Anything that is not a mapping is a version constraint and resolves
  /// remotely; a mapping counts as local exactly when it declares a `path`.
  static bool _isPathOverride(dynamic override) =>
      override is Map && override.containsKey('path');

  // ...........................................................................
  @override
  Future<void> get({required Directory directory, required GgLog ggLog}) async {
    await check(directory: directory);

    if (!checkProjectType(directory).isDartFamily) {
      return;
    }

    final statusPrinter = GgStatusPrinter<void>(
      ggLog: ggLog,
      message: 'No $fileName',
      dark: true,
    );
    statusPrinter.logStatus(GgStatusPrinterStatus.running);

    final file = File(p.join(directory.path, fileName));
    if (!hasLocalizedRefs(directory)) {
      statusPrinter.logStatus(GgStatusPrinterStatus.success);
      return;
    }

    statusPrinter.logStatus(GgStatusPrinterStatus.error);
    throw Exception(
      cError(
        '$fileName exists and would redirect dependencies to local paths. '
        'Delete "${file.path}" before publishing.',
      ),
    );
  }
}

// .............................................................................
/// A mocktail mock.
class MockNoPubspecOverrides extends mocktail.Mock
    implements NoPubspecOverrides {}
