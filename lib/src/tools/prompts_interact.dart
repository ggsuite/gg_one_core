// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:interact/interact.dart';

import 'prompts.dart';

/// SGR sequence switching the terminal back to its default colors.
const String colorOff = '\x1B[0m';

/// SGR sequence switching the terminal to blue until [colorOff] is written.
const String _blueOn = '\x1B[34m';

/// Matches the SGR sequences that set a foreground or background color —
/// the basic, bright, 256 and true colors. Bold, faint and resets do not
/// match.
final RegExp _colorSequence = RegExp(
  r'\x1B\[(?:3[0-9]|4[0-9]|9[0-7]|10[0-7])(?:;[0-9]+)*m',
);

/// Removes the colors from [text] and keeps every other text attribute.
String _uncolored(String text) => text.replaceAll(_colorSequence, '');

/// The theme of every gg prompt: the question is yellow, the cursor dark
/// gray, the option under it — and the answer picked — blue, every other
/// option white.
///
/// The theme owns the colors. Colors a caller put into the question or an
/// option are removed first, so no prompt can drift from the scheme. Other
/// attributes survive: an option emphasizes a part of itself, a command for
/// example, with [bold], which stands out in blue and in white alike.
/// Blue is taken — it marks the option under the cursor.
final Theme promptTheme = Theme.defaultTheme.copyWith(
  messageStyle: (text) => yellow(_uncolored(text)),
  valueStyle: (text) => blue(_uncolored(text)),
  activeItemPrefix: darkGray('❯'),
  activeItemStyle: (text) => blue(_uncolored(text)),
  inactiveItemStyle: (text) => white(_uncolored(text)),
);

/// The theme of the interactive message editors — the commit message of
/// `do commit` and the merge messages of `do configure-publish`. The prompt
/// is yellow, the message being edited is blue, like in [promptTheme].
///
/// The message cannot simply be wrapped in [blue]: interact's `readLine`
/// echoes the edit buffer raw and derives the cursor position from its
/// length, so embedded escape sequences would both end up in the message and
/// misplace the cursor. The prompt suffix therefore switches blue *on*, and
/// everything written after it — the edit buffer — comes out blue.
/// [Theme.valueStyle] colors the value the same way in the confirmation line
/// interact prints afterwards.
final Theme messageEditorTheme = promptTheme.copyWith(
  inputSuffix: '${promptTheme.inputSuffix}$_blueOn',
);

/// Builds the prompts of a native gg build.
GgPrompts createDefaultPrompts() => const InteractPrompts();

/// Draws the prompts with `package:interact`.
///
/// Only reachable on platforms that have `dart:ffi`; see [GgPrompts].
// coverage:ignore-start
class InteractPrompts extends GgPrompts {
  /// Default constructor
  const InteractPrompts();

  @override
  Future<int> select({
    required String prompt,
    required List<String> options,
    int initialIndex = 0,
  }) async => Select.withTheme(
    theme: promptTheme,
    prompt: prompt,
    options: options,
    initialIndex: initialIndex,
  ).interact();

  @override
  Future<String> input({
    required String prompt,
    String? defaultValue,
    String? initialText,
    bool asMessageEditor = false,
  }) async {
    if (!asMessageEditor) {
      return Input.withTheme(
        theme: promptTheme,
        prompt: prompt,
        defaultValue: defaultValue ?? '',
        initialText: initialText ?? '',
      ).interact();
    }

    try {
      return Input.withTheme(
        theme: messageEditorTheme,
        prompt: prompt,
        defaultValue: defaultValue ?? '',
        initialText: initialText ?? '',
      ).interact();
    } finally {
      stdout.write(colorOff);
    }
  }
}

// coverage:ignore-end
