// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The prompts a build without `dart:ffi` gets. A native test run picks the
// `package:interact` ones, so this imports the file directly — it is the
// half of the conditional import that a Wasm build sees.

import 'package:gg_one_core/src/tools/prompts.dart';
import 'package:gg_one_core/src/tools/prompts_unsupported.dart';
import 'package:test/test.dart';

void main() {
  group('UnsupportedPrompts', () {
    // #########################################################################
    test('is what createDefaultPrompts hands out', () {
      expect(createDefaultPrompts(), isA<UnsupportedPrompts>());
    });

    // #########################################################################
    test('refuses to select, naming the question', () {
      const prompts = UnsupportedPrompts();

      expect(
        () => prompts.select(prompt: 'Which increment?', options: ['a', 'b']),
        throwsA(
          isA<GgPromptsUnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('Which increment?'),
          ),
        ),
      );
    });

    // #########################################################################
    test('refuses to read input, naming the question', () {
      const prompts = UnsupportedPrompts();

      expect(
        () => prompts.input(prompt: 'Merge message'),
        throwsA(
          isA<GgPromptsUnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('Merge message'),
          ),
        ),
      );
    });

    // #########################################################################
    test('carries the reset sequence the message editor needs', () {
      // Re-exported so gg_multi_core can write it after an edit, whichever
      // half of the conditional import is in play.
      expect(colorOff, '\x1B[0m');
    });
  });
}
