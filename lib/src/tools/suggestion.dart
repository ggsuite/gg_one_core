// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_console_colors/gg_console_colors.dart';

/// Colorizes a suggestion like »Not committed yet. Please run
/// »gg do commit«.« — the prose becomes yellow ([cAction]), the commands
/// the guillemets mark become blue ([cCmd]), and the guillemets themselves
/// are dropped.
///
/// The two parts are colored separately and concatenated, never wrapped in
/// one another: nesting escape codes would make the inner color end at the
/// first reset and paint the rest of the line in the outer one.
///
/// A suggestion without guillemets is simply yellow.
String colorizeSuggestion(String suggestion) {
  final buffer = StringBuffer();
  var rest = suggestion;

  while (true) {
    final start = rest.indexOf('»');
    final end = start < 0 ? -1 : rest.indexOf('«', start + 1);
    if (start < 0 || end < 0) {
      // No (complete) command left — the remainder is prose.
      if (rest.isNotEmpty) buffer.write(cAction(rest));
      return buffer.toString();
    }

    final before = rest.substring(0, start);
    if (before.isNotEmpty) buffer.write(cAction(before));

    final command = rest.substring(start + 1, end);
    if (command.isNotEmpty) buffer.write(cCmd(command));

    rest = rest.substring(end + 1);
  }
}
