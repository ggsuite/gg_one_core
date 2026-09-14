// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_one_core/src/tools/prompts_interact.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:interact/interact.dart';
import 'package:test/test.dart';

void main() {
  group('createDefaultPrompts()', () {
    test('hands out the interact prompts on a native build', () {
      // Constructing them touches no terminal — only select() and input()
      // do, which is why they sit behind a coverage:ignore block.
      expect(createDefaultPrompts(), isA<InteractPrompts>());
    });
  });

  group('promptTheme', () {
    // The SGR codes of [text], e.g. {'33', '0'} for yellow text.
    Set<String> sgrCodes(String text) =>
        RegExp(r'\x1B\[([0-9;]*)m')
            .allMatches(text)
            .map((m) => m.group(1)!)
            .toSet();

    setUp(() => ggColorsEnabled = true);
    tearDown(() => ggColorsEnabled = null);

    test('prints the question in yellow', () {
      final styled = promptTheme.messageStyle('Select version increment:');
      expect(styled, yellow('Select version increment:'));
    });

    test('prints the option under the cursor in blue', () {
      final styled = promptTheme.activeItemStyle('Patch (1.0.0 -> 1.0.1)');
      expect(styled, blue('Patch (1.0.0 -> 1.0.1)'));
    });

    test('marks the option under the cursor with a dark gray cursor', () {
      expect(promptTheme.activeItemPrefix, darkGray('❯'));
      expect(promptTheme.activeItemPrefix, '\x1B[90m❯\x1B[0m');
    });

    test('prints the other options in white', () {
      final styled = promptTheme.inactiveItemStyle('Minor (1.0.0 -> 1.1.0)');
      expect(styled, white('Minor (1.0.0 -> 1.1.0)'));
    });

    test('prints the picked answer in blue', () {
      final styled = promptTheme.valueStyle(' Patch ');
      expect(styled, blue(' Patch '));
    });

    test('replaces the colors a caller put into the texts', () {
      final question = promptTheme.messageStyle(
        '\n${cH1('What should happen to the ticket when ready?')}',
      );
      expect(sgrCodes(question), {'33', '0'});
      expect(
        rmConsoleColors(question),
        '\nWhat should happen to the ticket when ready?',
      );

      final option =
          '${cAction('Remove it manually with ')}'
          '${cCmd('»gg do rm ticket 1«')}';
      expect(sgrCodes(promptTheme.activeItemStyle(option)), {'34', '0'});
      expect(sgrCodes(promptTheme.inactiveItemStyle(option)), {'37', '0'});
      expect(
        rmConsoleColors(promptTheme.inactiveItemStyle(option)),
        'Remove it manually with »gg do rm ticket 1«',
      );

      // Bright, 256 and true colors, foreground and background.
      const exotic =
          '\x1B[92ma\x1B[0m\x1B[38;5;196mb\x1B[0m'
          '\x1B[48;2;1;2;3mc\x1B[0m\x1B[104md\x1B[0m';
      expect(sgrCodes(promptTheme.inactiveItemStyle(exotic)), {'37', '0'});
    });

    test('keeps bold, which emphasizes a part of an option', () {
      final option = 'Remove it manually with ${bold('»gg do rm ticket 1«')}';

      final active = promptTheme.activeItemStyle(option);
      expect(sgrCodes(active), {'34', '1', '0'});
      expect(active, startsWith('\x1B[34mRemove it manually with \x1B[1m'));

      final inactive = promptTheme.inactiveItemStyle(option);
      expect(sgrCodes(inactive), {'37', '1', '0'});
      expect(inactive, startsWith('\x1B[37mRemove it manually with \x1B[1m'));
    });
  });

  group('messageEditorTheme', () {
    test('prints the prompt in yellow', () {
      final styled = messageEditorTheme.messageStyle('Edit commit message');
      expect(styled, yellow('Edit commit message'));
      expect(rmControls(styled), 'Edit commit message');
    });

    test('prints the entered message in blue', () {
      final styled = messageEditorTheme.valueStyle(' My message ');
      expect(styled, blue(' My message '));
      expect(rmControls(styled), ' My message ');
    });

    test('switches to blue after the prompt so the edit buffer is blue', () {
      // interact echoes the edit buffer raw right after the input suffix, so
      // the color has to be turned on there and stay on.
      expect(
        messageEditorTheme.inputSuffix,
        startsWith(Theme.defaultTheme.inputSuffix),
      );
      expect(messageEditorTheme.inputSuffix, endsWith('\x1B[34m'));
      expect(messageEditorTheme.inputSuffix, isNot(endsWith(colorOff)));
    });

    test('colorOff resets the terminal', () {
      expect(colorOff, '\x1B[0m');
      expect(rmControls(colorOff), isEmpty);
    });
  });
}
