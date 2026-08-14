// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_lang/gg_lang.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one_core/src/tools/analyzer.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart' as mocktail;

// #############################################################################

/// Runs static analysis on the source code, dispatching to the right
/// [Analyzer] based on the detected [ProjectType].
///
/// Cross-language bridge repos (see [isBridgeProject]) are analyzed as
/// TypeScript, so their package.json `lint` script drives the check.
class Analyze extends DirCommand<void> {
  /// Constructor.
  Analyze({
    required super.ggLog,
    Analyzer? dartAnalyzer,
    Analyzer? typeScriptAnalyzer,
  }) : _dartAnalyzer = dartAnalyzer ?? const DartAnalyzer(),
       _typeScriptAnalyzer = typeScriptAnalyzer ?? const TypeScriptAnalyzer(),
       super(name: 'analyze', description: 'Runs static analysis.');

  final Analyzer _dartAnalyzer;
  final Analyzer _typeScriptAnalyzer;

  // ...........................................................................
  @override
  Future<void> get({required Directory directory, required GgLog ggLog}) async {
    await check(directory: directory);

    final type = checkProjectType(directory);

    if (type == ProjectType.none) {
      GgStatusPrinter<void>(
        ggLog: ggLog,
        message: 'Skipping analyze (no project manifest)',
        dark: true,
      ).logStatus(GgStatusPrinterStatus.success);
      return;
    }

    final analyzer = switch (type) {
      ProjectType.dart || ProjectType.flutter => _dartAnalyzer,
      ProjectType.typescript || ProjectType.none => _typeScriptAnalyzer,
    };

    await analyzer.run(directory: directory, ggLog: ggLog);
  }
}

// .............................................................................
/// A mocktail mock.
class MockAnalyze extends mocktail.Mock implements Analyze {}
