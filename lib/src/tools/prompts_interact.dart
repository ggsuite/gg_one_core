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

/// Matches an SGR sequence — `ESC [ parameters m` — and captures its
/// parameters. Other escape sequences, a cursor movement or an OSC 8 link,
/// and the same characters without the escape do not match.
final RegExp _sgrSequence = RegExp(r'\x1B\[([0-9;:]*)m');

/// The SGR codes ending a text attribute, by the codes switching it on.
const Map<int, int> _attributeOff = <int, int>{
  1: 22, // bold
  2: 22, // faint
  3: 23, // italic
  4: 24, // underline
  21: 24, // double underline
  5: 25, // blink
  6: 25, // rapid blink
  7: 27, // inverse
  8: 28, // hidden
  9: 29, // strikethrough
  53: 55, // overline
};

/// The SGR codes that carry their color in the parameters after them.
const Set<int> _extendedColors = <int>{38, 48, 58};

/// Whether the SGR [code] sets or resets a foreground, background or
/// underline color.
bool _isColor(int code) =>
    (code >= 30 && code <= 49) ||
    (code >= 90 && code <= 97) ||
    (code >= 100 && code <= 107) ||
    code == 58 ||
    code == 59;

/// How many of the parameters after an extended color code belong to the
/// color, by its [mode]: `5;n` or `2;r;g;b`.
int _extendedColorLength(String mode) => mode == '5'
    ? 2
    : mode == '2'
    ? 4
    : 0;

/// Removes the colors from [text] and keeps its other attributes.
///
/// The colors belong to the theme. A reset inside [text] would end the
/// theme's color along with everything else, so it only ends the attributes
/// [text] switched on before it: the rest of the text keeps the theme's
/// color and is neither bold nor underlined any more.
String _uncolored(String text) {
  final switchedOn = <int>{};

  return text.replaceAllMapped(_sgrSequence, (match) {
    final parameters = match.group(1)!.split(';');
    final kept = <String>[];

    for (var i = 0; i < parameters.length; i++) {
      // A colon separates the sub-parameters of one parameter: 38:5:208.
      final subParameters = parameters[i].split(':');
      // An empty parameter means 0, the reset.
      final code = int.tryParse(subParameters.first) ?? 0;

      if (code == 0) {
        kept.addAll({for (final on in switchedOn) '${_attributeOff[on]}'});
        switchedOn.clear();
      } else if (_isColor(code)) {
        if (subParameters.length == 1 && _extendedColors.contains(code)) {
          final mode = i + 1 < parameters.length ? parameters[i + 1] : '';
          i += _extendedColorLength(mode);
        }
      } else {
        kept.add(parameters[i]);
        if (_attributeOff.containsKey(code)) {
          switchedOn.add(code);
        } else {
          switchedOn.removeWhere((on) => _attributeOff[on] == code);
        }
      }
    }

    return kept.isEmpty ? '' : '\x1B[${kept.join(';')}m';
  });
}

/// The theme of every gg prompt: the question is yellow, the cursor dark
/// gray, the option under it — and the answer picked — blue, every other
/// option white.
///
/// The theme owns the colors. Colors a caller put into the question or an
/// option are removed first, so no prompt can drift from the scheme. The
/// other attributes survive: an option emphasizes a part of itself, a
/// command for example, with [bold], which stands out in blue and in white
/// alike. Blue is taken — it marks the option under the cursor.
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

/// Builds the select prompt [InteractPrompts.select] draws, in
/// [promptTheme].
///
/// Building touches no terminal — only `interact()` does — so a test can
/// check the theme the prompt is drawn in.
Select buildSelect({
  required String prompt,
  required List<String> options,
  int initialIndex = 0,
}) => Select.withTheme(
  theme: promptTheme,
  prompt: prompt,
  options: options,
  initialIndex: initialIndex,
);

/// Builds the input prompt [InteractPrompts.input] draws: in
/// [messageEditorTheme] for a commit or merge message, in [promptTheme]
/// otherwise.
///
/// Building touches no terminal — only `interact()` does.
Input buildInput({
  required String prompt,
  String? defaultValue,
  String? initialText,
  bool asMessageEditor = false,
}) => Input.withTheme(
  theme: asMessageEditor ? messageEditorTheme : promptTheme,
  prompt: prompt,
  defaultValue: defaultValue ?? '',
  initialText: initialText ?? '',
);

/// Builds the prompts of a native gg build.
GgPrompts createDefaultPrompts() => const InteractPrompts();

/// Draws the prompts with `package:interact`.
///
/// Only reachable on platforms that have `dart:ffi`; see [GgPrompts]. The
/// prompts are built by [buildSelect] and [buildInput]; what is left here
/// needs a terminal.
// coverage:ignore-start
class InteractPrompts extends GgPrompts {
  /// Default constructor
  const InteractPrompts();

  @override
  Future<int> select({
    required String prompt,
    required List<String> options,
    int initialIndex = 0,
  }) async => buildSelect(
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
    final component = buildInput(
      prompt: prompt,
      defaultValue: defaultValue,
      initialText: initialText,
      asMessageEditor: asMessageEditor,
    );
    if (!asMessageEditor) {
      return component.interact();
    }

    try {
      return component.interact();
    } finally {
      stdout.write(colorOff);
    }
  }
}

// coverage:ignore-end
