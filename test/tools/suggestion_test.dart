// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:test/test.dart';

void main() {
  group('colorizeSuggestion', () {
    test('paints the prose yellow and the command blue', () {
      final result = colorizeSuggestion(
        'Not committed yet. Please run »gg do commit«.',
      );

      expect(
        result,
        cAction('Not committed yet. Please run ') +
            cCmd('gg do commit') +
            cAction('.'),
      );

      // The guillemets only mark the command — they are not printed.
      expect(rmControls(result), 'Not committed yet. Please run gg do commit.');
    });

    test('handles a suggestion that starts with the command', () {
      final result = colorizeSuggestion('»gg do push« first.');

      expect(result, cCmd('gg do push') + cAction(' first.'));
      expect(rmControls(result), 'gg do push first.');
    });

    test('handles several commands in one suggestion', () {
      final result = colorizeSuggestion('Run »a« or »b«.');

      expect(
        result,
        cAction('Run ') +
            cCmd('a') +
            cAction(' or ') +
            cCmd('b') +
            cAction('.'),
      );
    });

    test('paints a suggestion without a command yellow', () {
      final result = colorizeSuggestion('Nothing to do here.');

      expect(result, cAction('Nothing to do here.'));
    });

    test('leaves an unclosed guillemet as prose', () {
      // Half a marker is no command — printing the raw text beats
      // swallowing the rest of the line.
      final result = colorizeSuggestion('Please run »gg do commit');

      expect(result, cAction('Please run »gg do commit'));
    });

    test('drops empty parts instead of emitting bare escape codes', () {
      expect(colorizeSuggestion(''), '');
      expect(colorizeSuggestion('»gg do push«'), cCmd('gg do push'));
    });
  });
}
