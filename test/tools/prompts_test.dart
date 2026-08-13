// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_one_core/gg_one_core.dart';
import 'package:test/test.dart';

// .............................................................................
/// Answers from a script instead of asking anybody.
class _ScriptedPrompts extends GgPrompts {
  const _ScriptedPrompts(this.answer);

  final int answer;

  @override
  Future<int> select({
    required String prompt,
    required List<String> options,
    int initialIndex = 0,
  }) async => answer;

  @override
  Future<String> input({
    required String prompt,
    String? defaultValue,
    String? initialText,
    bool asMessageEditor = false,
  }) async => 'scripted';
}

void main() {
  tearDown(() => GgPrompts.current = null);

  group('GgPrompts', () {
    // #########################################################################
    group('current', () {
      test('starts out as the prompts of this platform', () {
        expect(GgPrompts.current, GgPrompts.defaultPrompts);
      });

      test('can be replaced and reset', () {
        const scripted = _ScriptedPrompts(1);

        GgPrompts.current = scripted;
        expect(GgPrompts.current, scripted);

        GgPrompts.current = null;
        expect(GgPrompts.current, GgPrompts.defaultPrompts);
      });

      test('is what the suite asks its questions through', () async {
        GgPrompts.current = const _ScriptedPrompts(2);

        expect(
          await GgPrompts.current.select(prompt: 'Pick', options: ['a', 'b']),
          2,
        );
        expect(await GgPrompts.current.input(prompt: 'Say'), 'scripted');
      });
    });

    // #########################################################################
    group('is asynchronous', () {
      test('so an embedder is free to read a line however it can', () {
        // The file system callbacks of GgHost have to be synchronous —
        // dart:io's ...Sync APIs cannot await. A prompt has no such
        // constraint, and forcing one would make an embedder block on its
        // input, which not every platform allows.
        const scripted = _ScriptedPrompts(0);
        expect(
          scripted.select(prompt: 'p', options: ['a']),
          isA<Future<int>>(),
        );
        expect(scripted.input(prompt: 'p'), isA<Future<String>>());
      });
    });
  });

  // ###########################################################################
  group('GgPromptsUnsupportedError', () {
    test('names the question and what to do instead', () {
      final error = GgPromptsUnsupportedError('the version prompt');

      expect(error.message, contains('the version prompt'));
      expect(error.message, contains('command line'));
      expect(error.message, contains('GgPrompts.current'));
    });
  });
}
