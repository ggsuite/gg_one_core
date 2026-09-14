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
  // Colors on, so every comparison sees the escape sequences — a run with
  // NO_COLOR would otherwise compare plain text and pass without them.
  setUp(() => ggColorsEnabled = true);
  tearDown(() => ggColorsEnabled = null);

  group('createDefaultPrompts()', () {
    test('hands out the interact prompts on a native build', () {
      // Constructing them touches no terminal — only select() and input()
      // do, which is why they sit behind a coverage:ignore block.
      expect(createDefaultPrompts(), isA<InteractPrompts>());
    });
  });

  group('buildSelect()', () {
    test('builds the select prompt in the prompt theme', () {
      final select = buildSelect(
        prompt: 'Which one?',
        options: ['a', 'b'],
        initialIndex: 1,
      );
      expect(select.theme, same(promptTheme));
      expect(select.prompt, 'Which one?');
      expect(select.options, ['a', 'b']);
      expect(select.initialIndex, 1);
    });

    test('starts on the first option by default', () {
      expect(buildSelect(prompt: 'Q', options: ['a']).initialIndex, 0);
    });
  });

  group('buildInput()', () {
    test('builds a plain input in the prompt theme', () {
      final input = buildInput(prompt: 'Name?');
      expect(input.theme, same(promptTheme));
      expect(input.prompt, 'Name?');
      expect(input.defaultValue, '');
      expect(input.initialText, '');
    });

    test('builds a message editor in the message editor theme', () {
      final input = buildInput(
        prompt: 'Edit merge message:',
        defaultValue: 'Fix',
        initialText: 'Fix it',
        asMessageEditor: true,
      );
      expect(input.theme, same(messageEditorTheme));
      expect(input.prompt, 'Edit merge message:');
      expect(input.defaultValue, 'Fix');
      expect(input.initialText, 'Fix it');
    });
  });

  group('promptTheme', () {
    // What an option not under the cursor turns [text] into.
    String inactive(String text) => promptTheme.inactiveItemStyle(text);

    // The white option the theme should make of [text].
    String white(String text) => '\x1B[37m$text\x1B[0m';

    test('prints the question in yellow', () {
      expect(
        promptTheme.messageStyle('Select version increment:'),
        '\x1B[33mSelect version increment:\x1B[0m',
      );
    });

    test('prints the option under the cursor in blue', () {
      expect(
        promptTheme.activeItemStyle('Patch (1.0.0 -> 1.0.1)'),
        '\x1B[34mPatch (1.0.0 -> 1.0.1)\x1B[0m',
      );
    });

    test('marks the option under the cursor with a dark gray cursor', () {
      expect(promptTheme.activeItemPrefix, '\x1B[90m❯\x1B[0m');
    });

    test('prints the other options in white', () {
      expect(
        inactive('Minor (1.0.0 -> 1.1.0)'),
        '\x1B[37mMinor (1.0.0 -> 1.1.0)\x1B[0m',
      );
    });

    test('prints the picked answer in blue', () {
      expect(promptTheme.valueStyle(' Patch '), '\x1B[34m Patch \x1B[0m');
    });

    test('removes the colors a caller put into the texts', () {
      expect(
        promptTheme.messageStyle('\n${cH1('What should happen?')}'),
        '\x1B[33m\nWhat should happen?\x1B[0m',
      );
      expect(
        promptTheme.activeItemStyle(
          '${cAction('Remove it with ')}${cCmd('»gg do rm ticket 1«')}',
        ),
        '\x1B[34mRemove it with »gg do rm ticket 1«\x1B[0m',
      );
    });

    test('removes basic, bright, default, 256 and true colors', () {
      const colored = <String>[
        '\x1B[31ma\x1B[39m',
        '\x1B[92ma\x1B[39m',
        '\x1B[41ma\x1B[49m',
        '\x1B[104ma\x1B[49m',
        '\x1B[38;5;208ma',
        '\x1B[48;2;1;2;3ma',
        '\x1B[38:5:208ma',
        '\x1B[48:2::1:2:3ma',
        '\x1B[58;5;1ma\x1B[59m',
        '\x1B[38ma',
      ];
      for (final text in colored) {
        expect(inactive(text), white('a'), reason: text);
      }
    });

    test('keeps the attributes next to a color in one sequence', () {
      expect(inactive('\x1B[1;33ma'), white('\x1B[1ma'));
      expect(inactive('\x1B[33;1ma'), white('\x1B[1ma'));
      expect(inactive('\x1B[1;38;5;208;4ma'), white('\x1B[1;4ma'));
      expect(inactive('\x1B[48;2;1;2;3;3ma'), white('\x1B[3ma'));
      expect(inactive('\x1B[38:5:208;4:3ma'), white('\x1B[4:3ma'));
    });

    test('keeps bold, which emphasizes a part of an option', () {
      final option = 'Remove it manually with ${bold('»gg do rm ticket 1«')}';

      expect(
        promptTheme.activeItemStyle(option),
        '\x1B[34mRemove it manually with '
        '\x1B[1m»gg do rm ticket 1«\x1B[22m\x1B[0m',
      );
      expect(
        inactive(option),
        white('Remove it manually with \x1B[1m»gg do rm ticket 1«\x1B[22m'),
      );
    });

    test('ends at a reset only the attributes switched on before it', () {
      // The text after a reset keeps the theme's color and loses the
      // attributes — however the reset is spelled.
      expect(
        inactive('Run ${bold('gg do push')} first'),
        white('Run \x1B[1mgg do push\x1B[22m first'),
      );
      expect(inactive('\x1B[3mx\x1B[m y'), white('\x1B[3mx\x1B[23m y'));
      expect(inactive('\x1B[1;4mx\x1B[0m y'), white('\x1B[1;4mx\x1B[22;24m y'));
      expect(inactive('\x1B[1;2mx\x1B[0m'), white('\x1B[1;2mx\x1B[22m'));
      expect(inactive('\x1B[1mx\x1B[0;4my'), white('\x1B[1mx\x1B[22;4my'));
      expect(
        inactive('\x1B[5;7;8;9;21;53mx\x1B[0m'),
        white('\x1B[5;7;8;9;21;53mx\x1B[25;27;28;29;24;55m'),
      );
    });

    test('drops a reset that has nothing left to end', () {
      expect(inactive('\x1B[mx'), white('x'));
      expect(inactive('\x1B[0;1mx'), white('\x1B[1mx'));
      expect(inactive('\x1B[1mx\x1B[22my\x1B[0m'), white('\x1B[1mx\x1B[22my'));
    });

    test('leaves other escape sequences and plain brackets alone', () {
      const untouched = <String>[
        '\x1B]8;;https://example.com\x1B\\link\x1B]8;;\x1B\\',
        '\x1B[33Aup',
        '[33mno escape',
      ];
      for (final text in untouched) {
        expect(inactive(text), white(text), reason: text);
      }
    });
  });

  group('messageEditorTheme', () {
    test('prints the prompt in yellow', () {
      final styled = messageEditorTheme.messageStyle('Edit commit message');
      expect(styled, '\x1B[33mEdit commit message\x1B[0m');
      expect(rmControls(styled), 'Edit commit message');
    });

    test('prints the entered message in blue', () {
      final styled = messageEditorTheme.valueStyle(' My message ');
      expect(styled, '\x1B[34m My message \x1B[0m');
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
