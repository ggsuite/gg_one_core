// @license
// Copyright (c) 2019 - 2024 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_args/gg_args.dart';
import 'package:gg_git/gg_git.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one_core/src/commands/check/analyze.dart';
import 'package:gg_one_core/src/commands/check/build.dart';
import 'package:gg_one_core/src/commands/check/format.dart';
import 'package:gg_one_core/src/commands/check/no_pubspec_overrides.dart';
import 'package:gg_one_core/src/commands/check/npm_logged_in.dart';
import 'package:gg_one_core/src/commands/check/package_json_scripts.dart';
import 'package:gg_one_core/src/commands/check/pana.dart';
import 'package:gg_one_core/src/commands/check/pub_get_offline.dart';
import 'package:gg_publish/gg_publish.dart';
import 'package:gg_test/gg_test.dart';
import 'package:gg_version/gg_version.dart';

// .............................................................................
/// Dependencies for the check command
class Checks {
  /// Constructor
  Checks({
    required this.ggLog,
    PubGetOffline? pubGetOffline,
    Analyze? analyze,
    Build? build,
    Format? format,
    Tests? tests,
    CheckPackageJsonScripts? packageJsonScripts,
    Pana? pana,
    NpmLoggedIn? npmLoggedIn,
    NoPubspecOverrides? noPubspecOverrides,
    IsPushed? isPushed,
    IsCommitted? isCommitted,
    IsVersioned? isVersioned,
    IsPublished? isPublished,
    IsUpgraded? isUpgraded,
  }) : pubGetOffline = pubGetOffline ?? PubGetOffline(ggLog: ggLog),
       analyze = analyze ?? Analyze(ggLog: ggLog),
       build = build ?? Build(ggLog: ggLog),
       format = format ?? Format(ggLog: ggLog),
       tests = tests ?? Tests(ggLog: ggLog),
       packageJsonScripts =
           packageJsonScripts ?? CheckPackageJsonScripts(ggLog: ggLog),
       pana = pana ?? Pana(ggLog: ggLog),
       npmLoggedIn = npmLoggedIn ?? NpmLoggedIn(ggLog: ggLog),
       noPubspecOverrides =
           noPubspecOverrides ?? NoPubspecOverrides(ggLog: ggLog),
       isPushed = isPushed ?? IsPushed(ggLog: ggLog),
       isCommitted = isCommitted ?? IsCommitted(ggLog: ggLog),
       isVersioned = isVersioned ?? IsVersioned(ggLog: ggLog),
       isPublished = isPublished ?? IsPublished(ggLog: ggLog),
       isUpgraded = isUpgraded ?? IsUpgraded(ggLog: ggLog) {
    _initAll();
  }

  /// The log function
  final GgLog ggLog;

  /// The pub-get-offline command
  final PubGetOffline pubGetOffline;

  /// The analyze command
  final Analyze analyze;

  /// The build command (bridge repos only)
  final Build build;

  /// The format command
  final Format format;

  /// The coverage command
  final Tests tests;

  /// The package.json scripts check (TypeScript projects only)
  final CheckPackageJsonScripts packageJsonScripts;

  /// The pana command
  final Pana pana;

  /// The npm-logged-in command (npm-published TypeScript packages only)
  final NpmLoggedIn npmLoggedIn;

  /// The no-pubspec-overrides check (Dart/Flutter packages only)
  final NoPubspecOverrides noPubspecOverrides;

  /// The isPushed command
  final IsPushed isPushed;

  /// The isCommitted command
  final IsCommitted isCommitted;

  /// The isVersioned command
  final IsVersioned isVersioned;

  /// The isPublished command
  final IsPublished isPublished;

  /// The isUpgraded command
  final IsUpgraded isUpgraded;

  /// Returns a list of all commands
  Iterable<DirCommand<void>> get all => _all;

  // ...........................................................................
  late List<DirCommand<void>> _all;

  void _initAll() {
    _all = [
      pubGetOffline,
      analyze,
      build,
      format,
      tests,
      packageJsonScripts,
      pana,
      npmLoggedIn,
      noPubspecOverrides,
      isPushed,
      isCommitted,
      isVersioned,
      isPublished,
      isUpgraded,
    ];
  }
}
