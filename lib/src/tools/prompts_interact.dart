// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
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

/// The theme of the interactive message editors — the commit message of
/// `do commit` and the merge messages of `do configure-publish`. The prompt
/// is yellow, the message being edited is blue.
///
/// The message cannot simply be wrapped in [blue]: interact's `readLine`
/// echoes the edit buffer raw and derives the cursor position from its
/// length, so embedded escape sequences would both end up in the message and
/// misplace the cursor. The prompt suffix therefore switches blue *on*, and
/// everything written after it — the edit buffer — comes out blue.
/// [Theme.valueStyle] colors the value the same way in the confirmation line
/// interact prints afterwards.
final Theme messageEditorTheme = Theme.defaultTheme.copyWith(
  messageStyle: yellow,
  valueStyle: blue,
  inputSuffix: '${Theme.defaultTheme.inputSuffix}$_blueOn',
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
  int select({
    required String prompt,
    required List<String> options,
    int initialIndex = 0,
  }) => Select(
    prompt: prompt,
    options: options,
    initialIndex: initialIndex,
  ).interact();

  @override
  String input({
    required String prompt,
    String? defaultValue,
    String? initialText,
    bool asMessageEditor = false,
  }) {
    if (!asMessageEditor) {
      return Input(
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
