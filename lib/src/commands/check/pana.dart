// @license
// Copyright (c) ggsuite
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
import 'package:gg_version/gg_version.dart';
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
    PublishedVersion? publishedVersion,
    FromGit? versionFromGit,
    bool? publishedOnly,
  }) : _publishTo = publishTo ?? PublishTo(ggLog: ggLog),
       _publishedVersion = publishedVersion ?? PublishedVersion(ggLog: ggLog),
       _versionFromGit = versionFromGit ?? FromGit(ggLog: ggLog),
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

    // Pana scores the package against its released state: it resolves the
    // `repository:` URL and expects to find the package on the default branch,
    // at the version pub.dev serves. Before the first release neither exists —
    // the feature branch was never merged, no tag was ever written — and pana
    // fails with problems the package itself cannot fix. Two questions decide
    // whether there is a released state to score against at all:
    //
    //   1. Does pub.dev already know a version of this package?
    //   2. Does this repository carry a version tag for that version?
    //
    // Only when both are answered with yes has a full release cycle happened
    // here. Anything else — a first publish, a repository whose tags never
    // arrived — skips pana instead of failing the whole `can publish`.
    final skipReason = await _missingReleaseHistory(directory, ggLog);
    if (skipReason != null) {
      GgStatusPrinter<void>(
        ggLog: ggLog,
        message: 'Skipping pana ($skipReason)',
        dark: true,
      ).logStatus(GgStatusPrinterStatus.success);
      return;
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
      // The details are what the user acts on, so they travel with the
      // exception instead of being logged separately: a caller that only
      // surfaces the error message would otherwise swallow them and leave
      // »run pana again« as the whole answer.
      //
      // The package is named because a ticket runs pana over many repos and
      // the raw report does not say which one produced it. The two colors are
      // concatenated rather than nested — nesting would reset the outer one.
      final details = _details(messages, errors);
      throw Exception(
        [
          '${cError('Pana failed in')} ${cPath(directory.path)}',
          if (details.isNotEmpty) details,
        ].join('\n'),
      );
    }
  }

  /// The process wrapper used to execute shell processes
  final GgProcessWrapper processWrapper;

  // ######################
  // Private
  // ######################

  final PublishTo _publishTo;
  final PublishedVersion _publishedVersion;
  final FromGit _versionFromGit;

  // ...........................................................................
  /// Returns why pana has no released state to score against, or null when it
  /// has one. See the call site for why the two questions are asked.
  Future<String?> _missingReleaseHistory(
    Directory directory,
    GgLog ggLog,
  ) async {
    final published = await _publishedVersion.latestVersionFor(
      target: PublishTarget.pubDev,
      directory: directory,
      ggLog: ggLog,
    );

    if (published == null) {
      return 'not on pub.dev yet';
    }

    // The tags of the whole repository, not only the ones on HEAD: the release
    // was tagged on the default branch, and pana runs from a feature branch.
    final tags = await _versionFromGit.allVersions(
      directory: directory,
      ggLog: ggLog,
    );

    if (!tags.contains(published)) {
      return 'no git tag $published';
    }

    return null;
  }

  // ...........................................................................
  String _details(List<String> messages, List<String> errors) => [
    ...errors,
    ...messages,
  ].where((e) => e.trim().isNotEmpty).join('\n').trim();

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
    final pana = ggPlatform.isWindows ? 'pana.bat' : 'pana';
    final result = await processWrapper.run(pana, [
      '--no-warning',
      '--json',
      '--no-dartdoc', // dartdoc is enforced using analysis_options.yaml
    ], workingDirectory: dir.path);

    // pana may print progress (e.g. "Resolving dependencies...") to stdout
    // before the JSON payload on a cold run. Skip any such preamble and
    // parse from the first object brace so a valid report is not rejected.
    final rawOutput = result.stdout.toString();
    final braceIndex = rawOutput.indexOf('{');
    if (braceIndex < 0) {
      return (1, _noReport(result), <String>[]);
    }

    final Map<String, dynamic> jsonOutput;
    try {
      jsonOutput =
          jsonDecode(rawOutput.substring(braceIndex)) as Map<String, dynamic>;
    } catch (e) {
      return (1, _noReport(result, reason: '$e'), <String>[]);
    }

    try {
      // Parse the JSON output to get the score
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
  /// Explains a pana run whose stdout carries no JSON report.
  ///
  /// pana prints its report to stdout and its log to stderr. When it fails
  /// before the report, stdout stays empty and only the exit code and stderr
  /// say why — pana 0.23.17 and later, for example, rejects every Windows
  /// temp folder as a sandbox output folder because the path contains »:«.
  List<String> _noReport(ProcessResult result, {String? reason}) => [
    reason == null
        ? 'pana printed no JSON report (exit code ${result.exitCode}).'
        : 'pana printed no valid JSON report '
              '(exit code ${result.exitCode}): $reason',
    ..._stderrProblems('${result.stderr}'),
  ];

  // ...........................................................................
  /// The part of pana's stderr worth showing when it printed no report.
  ///
  /// With `--json` pana logs one JSON record per line. Its SEVERE and SHOUT
  /// records name the failure; their stack traces are left out. A stderr
  /// without such records is shown by its last [_stderrTailLength] lines.
  static List<String> _stderrProblems(String stderr) {
    final lines = const LineSplitter()
        .convert(stderr)
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    final problems = <String>[];
    for (final line in lines) {
      final record = _logRecord(line);
      final level = record?['level'];
      if (level != 'SEVERE' && level != 'SHOUT') {
        continue;
      }

      final message = '${record!['message'] ?? ''}'.trim();
      final error = '${record['error'] ?? ''}'.split('\n').first.trim();
      final text = [
        if (message.isNotEmpty) message,
        if (error.isNotEmpty && error != message) error,
      ].join(' — ');
      problems.add('$level: $text');
    }

    if (problems.isNotEmpty) {
      return problems;
    }

    return lines.length > _stderrTailLength
        ? lines.sublist(lines.length - _stderrTailLength)
        : lines;
  }

  // ...........................................................................
  /// One record of pana's JSON log, or null when [line] is none.
  static Map<String, dynamic>? _logRecord(String line) {
    if (!line.startsWith('{')) {
      return null;
    }

    try {
      return jsonDecode(line) as Map<String, dynamic>;
    } on FormatException {
      return null;
    }
  }

  /// How many of its last lines a stderr without log records is shown by.
  static const int _stderrTailLength = 10;

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
