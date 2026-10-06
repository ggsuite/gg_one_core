// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

/// The length a commit message's first line was once limited to.
///
/// The limit is no longer enforced: a first line may be as long as needed.
/// The constant stays only for packages that still refer to it.
@Deprecated('The first line of a commit message is no longer limited.')
const int maxCommitMessageFirstLineLength = 60;

/// A commit message split into the summary line and its detail lines.
///
/// Both halves are kept apart on purpose: the [firstLine] travels into
/// `git log --oneline` and the pull-request title, the [details] into the
/// commit body and the pull-request description. Joining them into one string
/// early would make it impossible to render either place correctly.
class CommitMessage {
  /// Creates a commit message. [details] defaults to an empty list.
  CommitMessage({required this.firstLine, List<String>? details})
    : details = List<String>.unmodifiable(details ?? const <String>[]);

  /// The summary line — never empty, but of any length.
  final String firstLine;

  /// One entry per notable change, rendered as the commit body.
  final List<String> details;

  /// Parses free-form editor input: the first non-empty line becomes the
  /// [firstLine], every further non-empty line one [details] entry.
  ///
  /// Blank lines are separators, not content — the blank line an editor puts
  /// between summary and body must not become an empty detail.
  factory CommitMessage.parse(String text) {
    final lines = text
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      return CommitMessage(firstLine: '');
    }
    return CommitMessage(
      firstLine: lines.first.trim(),
      details: lines.skip(1).toList(),
    );
  }

  /// Reads a commit message from [json]. [where] names the source in error
  /// messages. Throws a [FormatException] when the shape is wrong or
  /// `firstLine` is empty.
  factory CommitMessage.fromJson(
    Map<String, dynamic> json, {
    required String where,
  }) {
    final rawFirstLine = json['firstLine'];
    if (rawFirstLine is! String) {
      throw FormatException('$where: "firstLine" must be a string.');
    }
    final firstLine = rawFirstLine.trim();
    final error = validationError(firstLine);
    if (error != null) {
      throw FormatException('$where: $error');
    }

    final rawDetails = json['details'];
    final details = <String>[];
    if (rawDetails != null) {
      if (rawDetails is! List) {
        throw FormatException('$where: "details" must be a list of strings.');
      }
      for (final detail in rawDetails) {
        if (detail is! String) {
          throw FormatException('$where: "details" entries must be strings.');
        }
        if (detail.trim().isEmpty) continue;
        details.add(detail.trim());
      }
    }
    return CommitMessage(firstLine: firstLine, details: details);
  }

  /// This message as a JSON map. `details` is omitted when empty so a
  /// hand-written config stays readable.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'firstLine': firstLine,
    if (details.isNotEmpty) 'details': details,
  };

  /// The message as git and `gh` receive it: summary, blank line, details.
  String get text =>
      details.isEmpty ? firstLine : '$firstLine\n\n${details.join('\n')}';

  /// Why [firstLine] is not a usable summary, or null when it is fine.
  ///
  /// The single place the rule lives — the interactive prompt, the `-m`
  /// option and the JSON reader all ask this method rather than carrying
  /// their own copy. Only an empty first line is rejected; its length is not
  /// limited.
  static String? validationError(String firstLine) {
    if (firstLine.trim().isEmpty) {
      return 'the commit message must not be empty.';
    }
    return null;
  }
}
