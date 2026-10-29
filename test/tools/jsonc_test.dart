// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';

import 'package:gg_one_core/gg_one_core.dart';
import 'package:test/test.dart';

void main() {
  group('Jsonc', () {
    // #########################################################################
    group('stripComments()', () {
      test('blanks comments and trailing commas, not strings', () {
        const text =
            '{"a": "// no comment, ]", // comment\n'
            '"b": ["x\\"/*", /* c */ ], /* open';
        expect(
          Jsonc.stripComments(text),
          '{"a": "// no comment, ]",           \n'
          '"b": ["x\\"/*"          ],        ',
        );
      });

      test('keeps the length and the line breaks', () {
        const text = '{\r\n  // a\r\n  "a": 1, /* b\r\n c */\r\n}';
        final stripped = Jsonc.stripComments(text);
        expect(stripped.length, text.length);
        expect(stripped, '{\r\n      \r\n  "a": 1      \r\n     \r\n}');
        expect(jsonDecode(stripped), {'a': 1});
      });

      test('keeps a comma that is followed by a value', () {
        expect(Jsonc.stripComments('[1, /* c */ 2]'), '[1,         2]');
      });

      test('copes with unterminated strings and a dangling comma', () {
        expect(Jsonc.stripComments('["abc'), '["abc');
        expect(Jsonc.stripComments('["abc\\'), '["abc\\');
        expect(Jsonc.stripComments('[1,'), '[1,');
        expect(Jsonc.stripComments('// only'), '       ');
      });
    });

    // #########################################################################
    group('lineAndColumn()', () {
      test('counts both from 1', () {
        const text = 'ab\ncd\n';
        expect(Jsonc.lineAndColumn(text, 0), (line: 1, column: 1));
        expect(Jsonc.lineAndColumn(text, 1), (line: 1, column: 2));
        expect(Jsonc.lineAndColumn(text, 3), (line: 2, column: 1));
        expect(Jsonc.lineAndColumn(text, 6), (line: 3, column: 1));
      });

      test('stays inside the text', () {
        expect(Jsonc.lineAndColumn('ab', 99), (line: 1, column: 3));
        expect(Jsonc.lineAndColumn('ab', -1), (line: 1, column: 1));
      });
    });
  });
}
