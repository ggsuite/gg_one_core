// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

/// Reads JSON with comments (`.jsonc`), the format of the files gg lets
/// the user edit.
abstract final class Jsonc {
  /// [text] without its `//` and `/* */` comments and without trailing commas
  /// — what `jsonDecode` accepts from a JSON-with-comments (`.jsonc`) file.
  ///
  /// Strings are copied verbatim, also when they contain `//` or `,]`. Every
  /// removed character becomes a space and every line break stays, so an
  /// offset into the result — the one of a [FormatException] thrown by
  /// `jsonDecode` — points to the same place in [text].
  static String stripComments(String text) {
    final out = StringBuffer();
    var i = 0;
    while (i < text.length) {
      final char = text[i];
      if (char == '"') {
        final end = _stringEnd(text, i);
        out.write(text.substring(i, end));
        i = end;
      } else if (_commentEnd(text, i) case final end?) {
        out.write(_blank(text.substring(i, end)));
        i = end;
      } else if (char == ',' && _closesNext(text, i + 1)) {
        // A trailing comma, easily left behind when a line is deleted.
        out.write(' ');
        i++;
      } else {
        out.write(char);
        i++;
      }
    }
    return out.toString();
  }

  /// The line and column — both counted from 1 — of [offset] in [text].
  static ({int line, int column}) lineAndColumn(String text, int offset) {
    final before = text.substring(0, offset.clamp(0, text.length));
    final lineStart = before.lastIndexOf('\n') + 1;
    return (
      line: '\n'.allMatches(before).length + 1,
      column: before.length - lineStart + 1,
    );
  }

  /// [text] with every character but a line break replaced by a space.
  static String _blank(String text) => text.replaceAll(_noLineBreak, ' ');

  static final RegExp _noLineBreak = RegExp(r'[^\r\n]');

  /// The index behind the string starting with the quote at [start].
  static int _stringEnd(String text, int start) {
    var i = start + 1;
    while (i < text.length && text[i] != '"') {
      i += text[i] == r'\' ? 2 : 1;
    }
    return i < text.length ? i + 1 : text.length;
  }

  /// The index behind the comment starting at [start], or null when no
  /// comment starts there.
  static int? _commentEnd(String text, int start) {
    if (text.startsWith('//', start)) {
      final end = text.indexOf('\n', start);
      return end < 0 ? text.length : end;
    }
    if (text.startsWith('/*', start)) {
      final end = text.indexOf('*/', start + 2);
      return end < 0 ? text.length : end + 2;
    }
    return null;
  }

  /// Whether the next character after [start] that is neither white space
  /// nor part of a comment closes an object or a list.
  static bool _closesNext(String text, int start) {
    var i = start;
    while (i < text.length) {
      if (_commentEnd(text, i) case final end?) {
        i = end;
      } else if (text[i].trim().isEmpty) {
        i++;
      } else {
        return text[i] == '}' || text[i] == ']';
      }
    }
    return false;
  }
}
