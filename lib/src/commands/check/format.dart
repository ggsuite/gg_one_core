// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_lang/gg_lang.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one_core/src/tools/formatter.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart' as mocktail;

// #############################################################################

/// Applies formatting to the source code, dispatching to the right
/// [Formatter] based on the detected [ProjectType].
///
/// Cross-language bridge repos (see [isBridgeProject]) are formatted as
/// TypeScript, so their package.json `format` / `format:check` script drives
/// the check.
class Format extends DirCommand<void> {
  /// Constructor.
  Format({
    required super.ggLog,
    Formatter? dartFormatter,
    Formatter? typeScriptFormatter,
  }) : _dartFormatter = dartFormatter ?? const DartFormatter(),
       _typeScriptFormatter =
           typeScriptFormatter ?? const TypeScriptFormatter(),
       super(name: 'format', description: 'Runs the project formatter.');

  final Formatter _dartFormatter;
  final Formatter _typeScriptFormatter;

  // ...........................................................................
  @override
  Future<void> get({required Directory directory, required GgLog ggLog}) async {
    await check(directory: directory);

    final type = checkProjectType(directory);

    if (type == ProjectType.none) {
      GgStatusPrinter<void>(
        ggLog: ggLog,
        message: 'Skipping format (no project manifest)',
        dark: true,
      ).logStatus(GgStatusPrinterStatus.success);
      return;
    }

    final formatter = switch (type) {
      ProjectType.dart || ProjectType.flutter => _dartFormatter,
      ProjectType.typescript || ProjectType.none => _typeScriptFormatter,
    };

    await formatter.run(directory: directory, ggLog: ggLog);
  }
}

// .............................................................................
/// A mocktail mock.
class MockFormat extends mocktail.Mock implements Format {}
