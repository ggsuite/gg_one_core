// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'jsonc.dart';

/// The name of the per-repository gg settings file inside `.gg`.
const String repoGgRcFileName = 'gg_rc.jsonc';

/// The `.gg/gg_rc.jsonc` of the repository at [repoDir].
File repoGgRcFile(Directory repoDir) =>
    File(p.join(repoDir.path, '.gg', repoGgRcFileName));

/// The per-repository settings of gg, kept in `.gg/gg_rc.jsonc`.
///
/// The file is tracked by git, so the settings apply to everyone working on
/// the repository. Missing keys take their defaults.
class RepoGgRc {
  /// Creates the settings.
  const RepoGgRc({this.upgradeMajorVersions = true, this.enableChecks = true});

  /// Whether dependency upgrades may cross major versions
  /// (»dart pub upgrade --major-versions«, »pnpm update --latest«).
  final bool upgradeMajorVersions;

  /// Whether the checks before a commit (analyze, format, tests, …) run.
  /// false skips them, so everything can be committed.
  final bool enableChecks;

  /// The content a newly created file gets.
  static const String template =
      '// gg settings of this repository\n'
      '{\n'
      '  // false: upgrade dependencies without crossing major versions,\n'
      '  // i.e. without »--major-versions« / »--latest«\n'
      '  "upgradeMajorVersions": true,\n'
      '  // false: skip the checks before a commit and commit everything\n'
      '  "enableChecks": true\n'
      '}\n';

  /// The gitignore line that keeps the file tracked despite `.gg/*`.
  static const String gitignoreNegation = '!.gg/$repoGgRcFileName';

  /// Reads the settings of [repoDir] without touching the disk: a missing
  /// file yields the defaults.
  factory RepoGgRc.read(Directory repoDir) {
    final file = repoGgRcFile(repoDir);
    if (!file.existsSync()) return const RepoGgRc();
    return RepoGgRc.fromJsonString(file.readAsStringSync(), where: file.path);
  }

  /// Reads the settings of [repoDir]. Creates the file with its defaults
  /// when it does not exist yet.
  factory RepoGgRc.load(Directory repoDir) {
    final file = repoGgRcFile(repoDir);
    if (!file.existsSync()) {
      create(repoDir);
    }
    return RepoGgRc.read(repoDir);
  }

  /// Writes the default file into [repoDir] and makes sure a `.gg/*` rule
  /// in the root `.gitignore` does not hide it.
  static void create(Directory repoDir) {
    final file = repoGgRcFile(repoDir);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(template);
    _unignore(repoDir);
  }

  /// Parses [raw]. [where] names the source in error messages.
  factory RepoGgRc.fromJsonString(
    String raw, {
    String where = repoGgRcFileName,
  }) {
    final Object? json;
    try {
      json = jsonDecode(Jsonc.stripComments(raw));
    } on FormatException catch (e) {
      throw FormatException('$where is no valid JSON: ${e.message}');
    }
    if (json is! Map<String, dynamic>) {
      throw FormatException('$where must contain a JSON object.');
    }
    final map = json;
    bool flag(String key) {
      final value = map[key] ?? true;
      if (value is! bool) {
        throw FormatException('$where: »$key« must be a bool.');
      }
      return value;
    }

    return RepoGgRc(
      upgradeMajorVersions: flag('upgradeMajorVersions'),
      enableChecks: flag('enableChecks'),
    );
  }

  static void _unignore(Directory repoDir) {
    final gitignore = File(p.join(repoDir.path, '.gitignore'));
    if (!gitignore.existsSync()) return;
    final lines = gitignore.readAsStringSync().split('\n');
    final trimmed = lines.map((l) => l.trim()).toList();
    final star = trimmed.indexWhere((l) => l == '.gg/*' || l == '/.gg/*');
    if (star < 0 || trimmed.contains(gitignoreNegation)) return;
    lines.insert(star + 1, gitignoreNegation);
    gitignore.writeAsStringSync(lines.join('\n'));
  }
}
