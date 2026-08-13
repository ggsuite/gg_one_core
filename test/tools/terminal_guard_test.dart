// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:test/test.dart';

void main() {
  group('throwWhenNotATerminal', () {
    test('throws an actionable error when stdin is not a terminal', () {
      // The headless situation the guard protects against. The check is
      // injected because `dart test` hands the test isolate a stdin whose
      // `hasTerminal` differs per platform — on macOS it reports true.
      expect(
        () => throwWhenNotATerminal(
          'the version-increment prompt',
          'provide version_increment via .gg/gg-publish.json',
          hasTerminal: () => false,
        ),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            allOf(
              contains('stdin is not a terminal'),
              contains('the version-increment prompt'),
              contains('provide version_increment'),
            ),
          ),
        ),
      );
    });

    test('does not throw when stdin is a terminal', () {
      expect(
        () => throwWhenNotATerminal(
          'the version-increment prompt',
          'provide version_increment via .gg/gg-publish.json',
          hasTerminal: () => true,
        ),
        returnsNormally,
      );
    });
  });
}
