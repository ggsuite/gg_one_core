// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';

import 'package:gg_interact/gg_interact.dart';
import 'package:gg_publish/gg_publish.dart' show VersionIncrement;
import 'package:pub_semver/pub_semver.dart';

import 'commit_message.dart';
import 'jsonc.dart';
import 'publish_config.dart';

/// Lets the user edit a whole text in an editor; null when there is none.
/// [GgPrompts.editText] by default.
typedef EditText = Future<String?> Function({
  required String prompt,
  required String text,
  required String fileName,
});

/// The default [EditText]: whatever [GgPrompts.current] offers.
// coverage:ignore-start
Future<String?> defaultEditText({
  required String prompt,
  required String text,
  required String fileName,
}) =>
    GgPrompts.current.editText(prompt: prompt, text: text, fileName: fileName);
// coverage:ignore-end

// .............................................................................
/// What a [MessageSheet] lets the user edit for one repository.
///
/// A field is on the sheet when its value is not null — the value is the
/// default the field starts with and the answer when the user empties it.
class MessageSheetEntry {
  /// Constructor
  const MessageSheetEntry({
    required this.repo,
    this.commitMessage,
    this.mergeMessage,
    this.versionIncrement,
    this.baseline,
  });

  /// The repository's folder name — the key of its block on the sheet.
  final String repo;

  /// The message the repository's next commit is made with.
  final CommitMessage? commitMessage;

  /// The pull-request title and merge commit message of the repository.
  final String? mergeMessage;

  /// How the repository's next release bumps the version.
  final VersionIncrement? versionIncrement;

  /// The version the increment is applied to. Only shown, as a preview of
  /// the three increments.
  final Version? baseline;
}

// .............................................................................
/// The commit messages, merge messages and version increments of several
/// repositories as one file the user edits in their editor — instead of one
/// prompt per question and repository.
///
/// The file is JSON with comments (`.jsonc`), one block per repository. Every
/// message is a list of lines, so a message of several lines needs no `\n`:
///
/// ```jsonc
/// {
///   "gg_one_core": {
///     // 2.14.0 → patch 2.14.1 · minor 2.15.0 · major 3.0.0
///     "versionIncrement": "minor",
///     "mergeMessage": ["Edit the messages in VS Code"],
///     "commitMessage": ["Add MessageSheet", "Render and parse the sheet"]
///   }
/// }
/// ```
///
/// The sheet is only a view: callers read the defaults from the
/// repositories' `publish_config.json`, and write the edited values back.
class MessageSheet {
  /// Constructor
  MessageSheet({required this.entries});

  /// One entry per repository, in the order they are shown.
  final List<MessageSheetEntry> entries;

  /// The lines a first comment line starts with when the last edit could not
  /// be read. They are replaced on every attempt.
  static const String errorPrefix = '// ✗ ';

  /// The fields a repository's block can have, in the order they are shown.
  static const List<String> _fields = [
    'versionIncrement',
    'mergeMessage',
    'commitMessage',
  ];

  // ...........................................................................
  /// The sheet as the user sees it, headed by [title].
  String render({required String title}) {
    final buffer = StringBuffer()
      ..writeln('// $title')
      ..writeln('// Edit, then save and close this file to continue.')
      ..writeln(
        '// Each message is a list of lines, the first line sums it up.',
      );
    if (entries.any((e) => e.versionIncrement != null)) {
      buffer.writeln('// versionIncrement is "patch", "minor" or "major".');
    }
    buffer.writeln('{');

    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final fields = <String>[
        if (entry.versionIncrement != null)
          '"versionIncrement": ${jsonEncode(entry.versionIncrement!.name)}',
        if (entry.mergeMessage != null)
          '"mergeMessage": ${_lines(entry.mergeMessage!.split('\n'))}',
        if (entry.commitMessage != null)
          '"commitMessage": ${_lines(_commitLines(entry.commitMessage!))}',
      ];

      buffer.writeln('  ${jsonEncode(entry.repo)}: {');
      final preview = _preview(entry);
      if (preview != null) {
        buffer.writeln('    // $preview');
      }
      buffer.writeln(fields.map((f) => '    $f').join(',\n'));
      buffer.writeln(i == entries.length - 1 ? '  }' : '  },');
    }

    buffer.writeln('}');
    return buffer.toString();
  }

  // ...........................................................................
  /// Reads the edited [text] back. A field that was emptied or left out keeps
  /// its default. Throws a [FormatException] naming the problem — and for
  /// broken JSON, where it is — when the text is no valid sheet.
  List<MessageSheetEntry> parse(String text) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(Jsonc.stripComments(text));
    } on FormatException catch (e) {
      final offset = e.offset;
      final where = offset == null ? '' : ' ${_position(text, offset)}';
      throw FormatException('The file is no valid JSON$where: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('The file must contain one JSON object.');
    }

    final known = {for (final entry in entries) entry.repo};
    for (final repo in decoded.keys) {
      if (!known.contains(repo)) {
        throw FormatException(
          'Unknown repository "$repo". Expected one of ${known.join(', ')}.',
        );
      }
    }

    return [
      for (final entry in entries) _parseEntry(entry, decoded[entry.repo]),
    ];
  }

  // ...........................................................................
  /// Lets the user edit the sheet and returns the edited entries — or null
  /// when no editor can be opened, so the caller asks one by one instead.
  ///
  /// A sheet that cannot be read is opened again, headed by the reason. A
  /// sheet closed again unchanged after that ends the run with that reason,
  /// so a user who gives up is not trapped in a loop. A sheet saved empty
  /// cancels at once.
  Future<List<MessageSheetEntry>?> edit({
    required String title,
    required String fileName,
    EditText editText = defaultEditText,
  }) async {
    var text = render(title: title);
    var failedBefore = false;

    while (true) {
      final edited = await editText(
        prompt: title,
        text: text,
        fileName: fileName,
      );
      if (edited == null) {
        return null;
      }
      if (edited.trim().isEmpty) {
        throw Exception('Cancelled: $fileName was saved empty.');
      }

      try {
        return parse(edited);
      } on FormatException catch (e) {
        if (failedBefore && _normalized(edited) == _normalized(text)) {
          throw Exception('The messages were not saved: ${e.message}');
        }
        failedBefore = true;
        text = _withError(edited, e.message);
      }
    }
  }

  // ...........................................................................
  MessageSheetEntry _parseEntry(MessageSheetEntry entry, dynamic raw) {
    final repo = entry.repo;
    if (raw == null) {
      return entry;
    }
    if (raw is! Map<String, dynamic>) {
      throw FormatException('$repo must be a JSON object.');
    }

    // A typo would silently keep the default. A known field that is not on
    // this sheet is ignored: it may be left over from another sheet.
    for (final field in raw.keys) {
      if (!_fields.contains(field)) {
        throw FormatException(
          '$repo: unknown field "$field". '
          'Expected one of ${_fieldsOf(entry).join(', ')}.',
        );
      }
    }

    var versionIncrement = entry.versionIncrement;
    final rawIncrement = raw['versionIncrement'];
    if (entry.versionIncrement != null && rawIncrement != null) {
      if (rawIncrement is! String ||
          !allowedVersionIncrements.contains(rawIncrement.trim())) {
        throw FormatException(
          '$repo: "versionIncrement" must be "patch", "minor" or "major".',
        );
      }
      versionIncrement = parseVersionIncrement(rawIncrement.trim());
    }

    var mergeMessage = entry.mergeMessage;
    if (entry.mergeMessage != null) {
      final lines = _readLines(raw['mergeMessage'], '$repo: "mergeMessage"');
      if (lines.isNotEmpty) {
        mergeMessage = [lines.first.trim(), ...lines.skip(1)].join('\n');
      }
    }

    var commitMessage = entry.commitMessage;
    if (entry.commitMessage != null) {
      final lines = _readLines(raw['commitMessage'], '$repo: "commitMessage"');
      if (lines.isNotEmpty) {
        // The rules of a commit message typed on the terminal.
        commitMessage = CommitMessage.parse(lines.join('\n'));
      }
    }

    return MessageSheetEntry(
      repo: repo,
      commitMessage: commitMessage,
      mergeMessage: mergeMessage,
      versionIncrement: versionIncrement,
      baseline: entry.baseline,
    );
  }

  /// The fields of [entry] that are on the sheet — all fields for an entry
  /// without any.
  static List<String> _fieldsOf(MessageSheetEntry entry) {
    final fields = [
      if (entry.versionIncrement != null) 'versionIncrement',
      if (entry.mergeMessage != null) 'mergeMessage',
      if (entry.commitMessage != null) 'commitMessage',
    ];
    return fields.isEmpty ? _fields : fields;
  }

  /// The lines of a message field: a list of strings or — written by hand —
  /// one string. Empty lines around the message are dropped; an empty result
  /// means »keep the default«.
  static List<String> _readLines(dynamic raw, String where) {
    final List<String> lines;
    if (raw == null) {
      lines = const [];
    } else if (raw is String) {
      lines = raw.split('\n');
    } else if (raw is List && raw.every((line) => line is String)) {
      lines = [for (final line in raw.cast<String>()) ...line.split('\n')];
    } else {
      throw FormatException('$where must be a list of strings.');
    }

    var start = 0;
    var end = lines.length;
    while (start < end && lines[start].trim().isEmpty) {
      start++;
    }
    while (end > start && lines[end - 1].trim().isEmpty) {
      end--;
    }
    return [for (final line in lines.sublist(start, end)) line.trimRight()];
  }

  static List<String> _commitLines(CommitMessage message) => [
    message.firstLine,
    ...message.details,
  ];

  /// A list of lines on one line when it is short, one line per entry else.
  static String _lines(List<String> lines) {
    final oneLine = '[${lines.map(jsonEncode).join(', ')}]';
    if (lines.length <= 1 && oneLine.length <= 60) {
      return oneLine;
    }
    final inner = lines.map((line) => '      ${jsonEncode(line)}').join(',\n');
    return '[\n$inner\n    ]';
  }

  /// The three versions the increments would produce, or null without a
  /// baseline.
  static String? _preview(MessageSheetEntry entry) {
    final baseline = entry.baseline;
    if (entry.versionIncrement == null || baseline == null) {
      return null;
    }
    return '$baseline → patch ${baseline.nextPatch} · '
        'minor ${baseline.nextMinor} · major ${baseline.nextMajor}';
  }

  /// Where [offset] is in [text], as the user's editor counts.
  static String _position(String text, int offset) {
    final (:line, :column) = Jsonc.lineAndColumn(text, offset);
    return 'at line $line, column $column';
  }

  /// [text] headed by [error] instead of the error of an earlier attempt.
  static String _withError(String text, String error) {
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    final kept = lines.skipWhile((line) => line.startsWith(errorPrefix));
    final reason = error.split('\n').map((line) => '$errorPrefix$line');
    return [...reason, ...kept].join('\n');
  }

  /// [text] without the differences an editor makes on its own: line ends,
  /// white space at the end of a line and around the text.
  static String _normalized(String text) => text
      .replaceAll('\r\n', '\n')
      .split('\n')
      .map((line) => line.trimRight())
      .join('\n')
      .trim();
}
