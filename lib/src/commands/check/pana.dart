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

// #############################################################################
typedef _TaskResult = (int, List<String>, List<String>);

// #############################################################################

/// Runs dart pana on the source code
class Pana extends DirCommand<void> {
  /// Constructor
  Pana({
    required super.ggLog,
    this.processWrapper = const GgProcessWrapper(),
    PublishTo? publishTo,
    bool? publishedOnly,
  }) : _publishTo = publishTo ?? PublishTo(ggLog: ggLog),
       _publishedOnlyFromConstructor = publishedOnly,
       super(name: 'pana', description: 'Runs »dart run pana«.') {
    _addArgs();
  }

  // ...........................................................................
  /// Executes the command
  @override
  Future<void> get({
    required Directory directory,
    required GgLog ggLog,
    bool? publishedOnly,
  }) async {
    await check(directory: directory);
    publishedOnly ??=
        _publishedOnlyFromArgs ?? _publishedOnlyFromConstructor ?? false;

    // Without a manifest there is no package pana could analyze.
    if (checkProjectType(directory) == ProjectType.none) {
      GgStatusPrinter<void>(
        ggLog: ggLog,
        message: 'Skipping pana (no project manifest)',
        dark: true,
      ).logStatus(GgStatusPrinterStatus.success);
      return;
    }

    // Pana only applies to packages published to pub.dev. For npm-only or
    // `none` (private) targets there is nothing to analyze, so make the skip
    // explicit instead of logging a misleading "Running pana".
    //
    // A hybrid that publishes to both registries *is* analyzed: its Dart side
    // goes to pub.dev like any other package. That is new — before, the single
    // publish target of a hybrid read `npm` and pana was skipped for it.
    if (publishedOnly) {
      final targets = await _publishTo.targets(directory);
      if (!targets.contains(PublishTarget.pubDev)) {
        GgStatusPrinter<void>(
          ggLog: ggLog,
          message: 'Skipping pana (${targets.label} target)',
          dark: true,
        ).logStatus(GgStatusPrinterStatus.success);
        return;
      }
    }

    final statusPrinter = GgStatusPrinter<ProcessResult>(
      ggLog: ggLog,
      message: 'Running pana',
      dark: true,
    );

    // Announce the command
    statusPrinter.logStatus(GgStatusPrinterStatus.running);
    final result = await _task(directory);
    final (code, messages, errors) = result;
    final success = code == 0;

    statusPrinter.logStatus(
      success ? GgStatusPrinterStatus.success : GgStatusPrinterStatus.error,
    );

    if (!success) {
      _logErrors(messages, errors);
    }

    if (code != 0) {
      throw Exception(
        cError('Pana failed. Run "${cCmd('pana')}" again to see details.'),
      );
    }
  }

  /// The process wrapper used to execute shell processes
  final GgProcessWrapper processWrapper;

  // ######################
  // Private
  // ######################

  final PublishTo _publishTo;

  // ...........................................................................
  void _logErrors(List<String> messages, List<String> errors) {
    final errorMsg = errors.where((e) => e.isNotEmpty).join('\n');
    final stdoutMsg = messages.where((e) => e.isNotEmpty).join('\n');

    if (errorMsg.isNotEmpty) {
      ggLog(errorMsg); // coverage:ignore-line
    }
    if (stdoutMsg.isNotEmpty) {
      ggLog(stdoutMsg);
    }
  }

  // ...........................................................................
  List<String> _readProblems(Map<String, dynamic> jsonOutput) {
    final problems = <String>[];
    final sections = jsonOutput['report']['sections'] as List<dynamic>;
    final failedSections = sections.where(
      (section) => section['status'] == 'failed',
    );

    for (final section in failedSections) {
      final summary = section['summary'] as String;
      final errorPoints = summary
          .split('###')
          .where((element) => element.contains('[x]'));

      for (final errorPoint in errorPoints) {
        final parts = errorPoint.split('\n').map((e) => e.trim());

        final title = parts.first;
        final details = parts.skip(1);

        final titleRed = cError(title);
        final detailsGray = details.map((e) => brightBlack(e)).join('\n');
        problems.add('\n$titleRed$detailsGray');
      }
    }
    return problems;
  }

  // ...........................................................................
  Future<_TaskResult> _task(Directory dir) async {
    // Make sure pana is installed
    await _installPana();

    // Run 'pana' and capture the output
    final pana = Platform.isWindows ? 'pana.bat' : 'pana';
    final result = await processWrapper.run(pana, [
      '--no-warning',
      '--json',
      '--no-dartdoc', // dartdoc is enforced using analysis_options.yaml
    ], workingDirectory: dir.path);

    try {
      // pana may print progress (e.g. "Resolving dependencies...") to stdout
      // before the JSON payload on a cold run. Skip any such preamble and
      // parse from the first object brace so a valid report is not rejected.
      final rawOutput = result.stdout.toString();
      final braceIndex = rawOutput.indexOf('{');
      final jsonString = braceIndex >= 0
          ? rawOutput.substring(braceIndex)
          : rawOutput;

      // Parse the JSON output to get the score
      final jsonOutput = jsonDecode(jsonString) as Map<String, dynamic>;
      final allowedMissingPoints = _ignoreMissingVersionInChangeLog(jsonOutput);
      final grantedPoints = jsonOutput['scores']['grantedPoints'];
      final maxPoints =
          jsonOutput['scores']['maxPoints'] - allowedMissingPoints;
      final complete = grantedPoints == maxPoints;
      final points = '$grantedPoints/$maxPoints';

      // Check if the score is less than 140
      if (!complete) {
        final errors = _readProblems(jsonOutput);

        return (1, <String>[], errors);
      } else {
        final messages = ['All pub points achieved: $points'];
        return (0, <String>[], messages);
      }
    } catch (e) {
      return (1, ['Error parsing pana output: $e'], <String>[]);
    }
  }

  // ...........................................................................
  bool? get _publishedOnlyFromArgs => argResults?['published-only'] as bool?;

  // ...........................................................................
  final bool? _publishedOnlyFromConstructor;

  // ...........................................................................
  void _addArgs() {
    argParser.addFlag(
      'published-only',
      help: 'Check only packages published to pub.dev.',
      negatable: true,
    );
  }

  // ...........................................................................
  /// Returns true if pana is installed
  Future<bool> _isPanaInstalled() async {
    // If a new version of pana is available, it needs to be updated.
    final result = await processWrapper.run('dart', ['pub', 'global', 'list']);

    if (result.exitCode != 0) {
      throw Exception(
        cError('Failed to check if pana is installed: ${result.stderr}'),
      );
    }

    return result.stdout.toString().contains(RegExp(r'[\n^\s]+pana\s+'));
  }

  // ...........................................................................
  Future<void> _installPana() async {
    if (await _isPanaInstalled()) {
      return;
    }

    final result = await processWrapper.run('dart', [
      'pub',
      'global',
      'activate',
      'pana',
    ]);

    if (result.exitCode != 0) {
      ggLog(result.stderr.toString());
      throw Exception(cError('Failed to install pana: ${result.stderr}'));
    }
  }

  // ...........................................................................
  int _ignoreMissingVersionInChangeLog(Map<String, dynamic> jsonOutput) {
    final report = jsonOutput['report'] as Map<String, dynamic>;
    final sections = (report['sections'] as List<dynamic>)
        .cast<Map<String, dynamic>>();

    for (final section in sections) {
      final granted = section['grantedPoints'] as int;
      final max = section['maxPoints'] as int;
      final missingPoints = max - granted;

      if (missingPoints == 0) {
        continue;
      }
      final summary = section['summary'] as String;
      final isVersionError = summary.contains(
        RegExp(
          r'`CHANGELOG.md` does not contain reference to the current version',
        ),
      );

      if (isVersionError && missingPoints == 5) {
        return missingPoints;
      }
    }
    return 0;
  }
}

// .............................................................................
/// A mocktail mock
class MockPana extends mocktail.Mock implements Pana {}
