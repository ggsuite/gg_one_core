// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_log/gg_log.dart';
import 'package:path/path.dart' as path;

import 'jsonc.dart';

/// Reads the user's settings — [GgRc.load] fits.
typedef ReadSettings = GgRc Function({required GgLog ggLog});

/// The settings of gg: the user's `~/.gg_rc` and a repository's
/// `.gg/gg_rc`, one JSON object each, with the same structure.
///
/// The keys follow the command path and end with the name of the flag they
/// preset — `{"do": {"add": {"transitive": false}}}` makes `gg do add` behave
/// as if `--no-transitive` was given. A flag given on the command line always
/// wins; the files only replace the built-in default.
///
/// Precedence: command line > repository file > user file > built-in
/// default. Some settings belong to one repository and can only be set in
/// its file ([repoDefaults]); the user file must not hold them.
///
/// [load] writes the user file with [builtInDefaults] spelled out when it is
/// missing, [loadRepo] the repository file with [repoDefaults] when asked to.
/// An existing file is never rewritten — not even to add a setting a newer gg
/// knows: what it leaves out takes its built-in default. Both files may
/// contain `//` and `/* */` comments.
class GgRc {
  /// Settings read from the user [file] and the repository [repoFile]; what
  /// they leave out takes its default.
  const GgRc({
    required this.values,
    this.file,
    this.repoValues = const <String, dynamic>{},
    this.repoFile,
  }) : error = null;

  /// The built-in defaults only — touches no file.
  const GgRc.defaults()
    : values = const <String, dynamic>{},
      file = null,
      repoValues = const <String, dynamic>{},
      repoFile = null,
      error = null;

  /// Settings that could not be read: every [flag] throws [error].
  const GgRc._broken({this.file, this.repoFile, required String this.error})
    : values = const <String, dynamic>{},
      repoValues = const <String, dynamic>{};

  /// The name of the user file in the home directory.
  static const String fileName = '.gg_rc';

  /// The name of the repository file inside the repository's `.gg` folder.
  static const String repoFileName = 'gg_rc';

  /// The environment variable that names another user file instead.
  static const String pathVariable = 'GG_RC';

  /// Whether dependency upgrades may cross major versions
  /// (»dart pub upgrade --major-versions«, »pnpm update --latest«).
  static const List<String> upgradeMajorVersions = <String>[
    'do',
    'upgrade',
    'deps',
    'majorVersions',
  ];

  /// Whether the checks before a commit (analyze, format, tests, …) run.
  static const List<String> commitChecks = <String>['can', 'commit', 'checks'];

  /// Every setting of the user file, with its built-in default.
  static const Map<String, dynamic> builtInDefaults = <String, dynamic>{
    'do': <String, dynamic>{
      'add': <String, dynamic>{'transitive': true},
      'publish': <String, dynamic>{'askTicketCleanup': false},
    },
  };

  /// The settings only a repository file may hold, with their defaults.
  static const Map<String, dynamic> repoDefaults = <String, dynamic>{
    'do': <String, dynamic>{
      'upgrade': <String, dynamic>{
        'deps': <String, dynamic>{'majorVersions': true},
      },
    },
    'can': <String, dynamic>{
      'commit': <String, dynamic>{'checks': true},
    },
  };

  /// The settings read from the user file — empty when it was just created.
  final Map<String, dynamic> values;

  /// The user file the settings come from; null when none was read.
  final File? file;

  /// The settings read from the repository file.
  final Map<String, dynamic> repoValues;

  /// The repository file the settings come from; null when none was read.
  final File? repoFile;

  /// Why a file could not be read — invalid JSON, no object, or a
  /// repository setting in the user file; null when both could. Thrown by
  /// [flag], so a run that reads no setting is not stopped by it.
  final String? error;

  // ...........................................................................
  /// The user file: `$GG_RC`, otherwise `.gg_rc` in the home directory.
  /// Null when neither the variable nor a home directory is known.
  static File? defaultFile({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final explicit = env[pathVariable];
    if (explicit != null && explicit.isNotEmpty) {
      return File(explicit);
    }
    final home = env['HOME'] ?? env['USERPROFILE'];
    if (home == null || home.isEmpty) {
      return null;
    }
    return File(path.join(home, fileName));
  }

  // ...........................................................................
  /// The `.gg/gg_rc` of the repository at [repo].
  static File repoFileOf(Directory repo) =>
      File(path.join(repo.path, '.gg', repoFileName));

  // ...........................................................................
  /// Reads the user [file] — by default [defaultFile] of [environment] — and
  /// writes it with [builtInDefaults] first when it does not exist yet. With
  /// [repo], the repository file is read on top; it takes precedence.
  ///
  /// A user file that cannot be written does not fail the command that
  /// asked: its settings are the defaults then. A file that cannot be read,
  /// holds no JSON object, or — the user file — holds a setting of
  /// [repoDefaults], makes every [flag] throw, naming the file and how to
  /// repair it: gg must not silently ignore settings the user wrote down,
  /// but a run that reads none of them, e.g. because the flag was given,
  /// goes on.
  factory GgRc.load({
    required GgLog ggLog,
    File? file,
    Map<String, String>? environment,
    Directory? repo,
  }) {
    final user = GgRc._loadUserFile(
      ggLog: ggLog,
      file: file ?? defaultFile(environment: environment),
    );
    if (repo == null || user.error != null) {
      return user;
    }
    final repoOnly = GgRc.loadRepo(repo);
    if (repoOnly.error != null) {
      return repoOnly;
    }
    return GgRc(
      values: user.values,
      file: user.file,
      repoValues: repoOnly.repoValues,
      repoFile: repoOnly.repoFile,
    );
  }

  // ...........................................................................
  /// Reads only the repository file of [repo] — enough for the settings of
  /// [repoDefaults], which the user file cannot hold — and touches no other
  /// file. With [create], a missing file is written with [repoDefaults] and
  /// `!.gg/gg_rc` is added below a `.gg/*` rule of the root `.gitignore`, so
  /// the file stays tracked.
  factory GgRc.loadRepo(Directory repo, {bool create = false}) {
    final file = repoFileOf(repo);
    if (!file.existsSync()) {
      if (create) {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(_pretty(repoDefaults));
        _unignore(repo);
      }
      return GgRc(values: const <String, dynamic>{}, repoFile: file);
    }

    final decoded = _decode(file);
    if (decoded case final String error) {
      return GgRc._broken(repoFile: file, error: error);
    }
    return GgRc(
      values: const <String, dynamic>{},
      repoValues: decoded as Map<String, dynamic>,
      repoFile: file,
    );
  }

  // ...........................................................................
  /// The boolean setting at [keys]: from the repository file when it holds
  /// one, else from the user file — not for a setting of [repoDefaults] —,
  /// else the built-in default.
  ///
  /// Throws when a file could not be read ([error]), when it holds something
  /// else than `true` or `false` there, and when gg knows no such setting.
  bool flag(List<String> keys) {
    if (error != null) {
      throw Exception(cError(error!));
    }
    final repoOnly = isRepoSetting(keys);
    final fromRepo = _lookup(repoValues, keys);
    final fromUser = repoOnly ? null : _lookup(values, keys);
    final own = fromRepo ?? fromUser;
    final value =
        own ?? _lookup(repoOnly ? repoDefaults : builtInDefaults, keys);
    if (value is bool) {
      return value;
    }
    if (own != null) {
      final source = fromRepo != null ? repoFile : file;
      throw Exception(
        cError(
          '"${keyPath(keys)}" in ${source?.path ?? fileName} must be true or '
          'false, not ${jsonEncode(value)}.',
        ),
      );
    }
    throw ArgumentError.value(keys, 'keys', 'gg knows no such setting');
  }

  // ...........................................................................
  /// Whether a file sets [keys] itself instead of leaving the default.
  bool isSet(List<String> keys) =>
      _lookup(repoValues, keys) != null ||
      (!isRepoSetting(keys) && _lookup(values, keys) != null);

  // ...........................................................................
  /// Whether [keys] is a setting only a repository file may hold.
  static bool isRepoSetting(List<String> keys) =>
      _lookup(repoDefaults, keys) != null;

  // ...........................................................................
  /// [keys] as they are written in a message: `do.add.transitive`.
  static String keyPath(List<String> keys) => keys.join('.');

  // ######################
  // Private
  // ######################

  factory GgRc._loadUserFile({required GgLog ggLog, required File? file}) {
    if (file == null) {
      return const GgRc.defaults();
    }

    if (!file.existsSync()) {
      try {
        file.writeAsStringSync(_pretty(builtInDefaults));
        ggLog(
          cDetail(
            '✓ Created ${file.path} — gg reads its defaults from there, '
            'e.g. {"do": {"add": {"transitive": false}}}.',
          ),
        );
      } on FileSystemException catch (e) {
        ggLog(
          cWarn(
            '⚠️ Could not create ${file.path} (${e.osError?.message ?? e}). '
            'gg uses its built-in defaults. Check that the folder is '
            'writable, or name another file in \$$pathVariable.',
          ),
        );
      }
      return GgRc(values: const <String, dynamic>{}, file: file);
    }

    final decoded = _decode(file);
    if (decoded case final String error) {
      return GgRc._broken(file: file, error: error);
    }
    final values = decoded as Map<String, dynamic>;
    final repoKey = _firstRepoSetting(values);
    if (repoKey != null) {
      return GgRc._broken(
        file: file,
        error:
            '"${keyPath(repoKey)}" cannot be set in ${file.path}: it belongs '
            'to one repository. Remove it there and set it in the '
            '.gg/$repoFileName of each repository that needs it.',
      );
    }
    return GgRc(values: values, file: file);
  }

  // ...........................................................................
  /// The JSON object in [file], or the message why it holds none.
  static Object _decode(File file) {
    const repair =
        'Fix it, or delete it and gg writes a fresh one with the defaults.';
    final Object? decoded;
    try {
      decoded = jsonDecode(Jsonc.stripComments(file.readAsStringSync()));
    } on FormatException catch (e) {
      return '${file.path} is no valid JSON: ${e.message}. $repair';
    }
    if (decoded is! Map<String, dynamic>) {
      return '${file.path} must hold one JSON object, '
          'e.g. {"do": {"add": {"transitive": false}}}. $repair';
    }
    return decoded;
  }

  // ...........................................................................
  /// The first setting of [repoDefaults] that [values] holds, or null.
  static List<String>? _firstRepoSetting(Map<String, dynamic> values) {
    List<String>? visit(Map<String, dynamic> defaults, List<String> prefix) {
      for (final entry in defaults.entries) {
        final keys = [...prefix, entry.key];
        final child = entry.value;
        if (child is Map<String, dynamic>) {
          final found = visit(child, keys);
          if (found != null) return found;
        } else if (_lookup(values, keys) != null) {
          return keys;
        }
      }
      return null;
    }

    return visit(repoDefaults, const <String>[]);
  }

  // ...........................................................................
  static String _pretty(Map<String, dynamic> map) =>
      '${const JsonEncoder.withIndent('  ').convert(map)}\n';

  // ...........................................................................
  /// Adds `!.gg/gg_rc` right below a `.gg/*` rule of the root `.gitignore`
  /// of [repo], so the repository file is tracked.
  static void _unignore(Directory repo) {
    final gitignore = File(path.join(repo.path, '.gitignore'));
    if (!gitignore.existsSync()) return;
    const negation = '!.gg/$repoFileName';
    final lines = gitignore.readAsStringSync().split('\n');
    final trimmed = lines.map((l) => l.trim()).toList();
    final star = trimmed.indexWhere((l) => l == '.gg/*' || l == '/.gg/*');
    if (star < 0 || trimmed.contains(negation)) return;
    lines.insert(star + 1, negation);
    gitignore.writeAsStringSync(lines.join('\n'));
  }

  // ...........................................................................
  static Object? _lookup(Map<String, dynamic> map, List<String> keys) {
    Object? current = map;
    for (final key in keys) {
      if (current is! Map<String, dynamic>) {
        return null;
      }
      current = current[key];
    }
    return current;
  }
}
