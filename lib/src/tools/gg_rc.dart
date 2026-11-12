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
const String ggRcFileName = 'gg_rc.jsonc';

/// The `.gg/gg_rc.jsonc` of the repository at [repoDir].
File ggRcFile(Directory repoDir) =>
    File(p.join(repoDir.path, '.gg', ggRcFileName));

/// The per-repository settings of gg, kept in `.gg/gg_rc.jsonc`.
///
/// The file is tracked by git, so the settings apply to everyone working on
/// the repository. Missing keys take their defaults.
class GgRc {
  /// Creates the settings.
  const GgRc({this.upgradeMajorVersions = true, this.enableChecks = true});

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
  static const String gitignoreNegation = '!.gg/$ggRcFileName';

  /// Reads the settings of [repoDir] without touching the disk: a missing
  /// file yields the defaults.
  factory GgRc.read(Directory repoDir) {
    final file = ggRcFile(repoDir);
    if (!file.existsSync()) return const GgRc();
    return GgRc.fromJsonString(file.readAsStringSync(), where: file.path);
  }

  /// Reads the settings of [repoDir]. Creates the file with its defaults
  /// when it does not exist yet.
  factory GgRc.load(Directory repoDir) {
    final file = ggRcFile(repoDir);
    if (!file.existsSync()) {
      create(repoDir);
    }
    return GgRc.read(repoDir);
  }

  /// Writes the default file into [repoDir] and makes sure a `.gg/*` rule
  /// in the root `.gitignore` does not hide it.
  static void create(Directory repoDir) {
    final file = ggRcFile(repoDir);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(template);
    _unignore(repoDir);
  }

  /// Parses [raw]. [where] names the source in error messages.
  factory GgRc.fromJsonString(String raw, {String where = ggRcFileName}) {
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

    return GgRc(
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
