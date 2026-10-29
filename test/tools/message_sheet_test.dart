// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_publish/gg_publish.dart' show VersionIncrement;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  final core = MessageSheetEntry(
    repo: 'core',
    versionIncrement: VersionIncrement.patch,
    mergeMessage: 'Ticket description',
    commitMessage: CommitMessage(firstLine: 'Add x', details: ['Detail']),
    baseline: Version(1, 2, 3),
  );
  const ui = MessageSheetEntry(repo: 'ui', mergeMessage: 'Ticket description');

  MessageSheet sheet() => MessageSheet(entries: [core, ui]);

  group('MessageSheet', () {
    // #########################################################################
    group('render()', () {
      test('shows every field of every repository', () {
        expect(
          sheet().render(title: 'gg do review'),
          [
            '// gg do review',
            '// Edit, then save and close this file to continue.',
            '// Each message is a list of lines, the first line sums it up.',
            '// versionIncrement is "patch", "minor" or "major".',
            '{',
            '  "core": {',
            '    // 1.2.3 → patch 1.2.4 · minor 1.3.0 · major 2.0.0',
            '    "versionIncrement": "patch",',
            '    "mergeMessage": ["Ticket description"],',
            '    "commitMessage": [',
            '      "Add x",',
            '      "Detail"',
            '    ]',
            '  },',
            '  "ui": {',
            '    "mergeMessage": ["Ticket description"]',
            '  }',
            '}',
            '',
          ].join('\n'),
        );
      });

      test('explains the increments only when one is asked', () {
        final text = MessageSheet(entries: [ui]).render(title: 't');
        expect(text, isNot(contains('versionIncrement')));
      });

      test('renders what it parses', () {
        final entries = sheet().parse(sheet().render(title: 't'));
        expect(entries[0].versionIncrement, VersionIncrement.patch);
        expect(entries[0].mergeMessage, 'Ticket description');
        expect(entries[0].commitMessage!.text, 'Add x\n\nDetail');
        expect(entries[0].baseline, Version(1, 2, 3));
        expect(entries[1].mergeMessage, 'Ticket description');
        expect(entries[1].commitMessage, isNull);
        expect(entries[1].versionIncrement, isNull);
      });

      test('puts a long message on several lines', () {
        final long = 'x' * 70;
        final text = MessageSheet(
          entries: [MessageSheetEntry(repo: 'r', mergeMessage: long)],
        ).render(title: 't');
        expect(text, contains('"mergeMessage": [\n      "$long"\n    ]'));
      });
    });

    // #########################################################################
    group('parse()', () {
      test('reads the edited values', () {
        final entries = sheet().parse('''
          // A comment
          {
            "core": {
              "versionIncrement": " minor ",
              "mergeMessage": ["Merge", "", "Body"],
              "commitMessage": ["", "Edited", "  ", "One", "Two ", ""],
            },
            /* block
               comment */
            "ui": {"mergeMessage": "UI merge"},
          }
          ''');

        expect(entries[0].versionIncrement, VersionIncrement.minor);
        expect(entries[0].mergeMessage, 'Merge\n\nBody');
        expect(entries[0].commitMessage!.firstLine, 'Edited');
        expect(entries[0].commitMessage!.details, ['One', 'Two']);
        expect(entries[1].mergeMessage, 'UI merge');
      });

      test('keeps the default of an emptied or missing field', () {
        final entries = sheet().parse('''
          {
            "core": {"mergeMessage": [], "commitMessage": ["  "]}
          }
          ''');

        expect(entries[0].versionIncrement, VersionIncrement.patch);
        expect(entries[0].mergeMessage, 'Ticket description');
        expect(entries[0].commitMessage!.firstLine, 'Add x');
        expect(entries[1].mergeMessage, 'Ticket description');
      });

      test('trims the first line of a message on both sides', () {
        final entries = sheet().parse('''
          {
            "core": {
              "mergeMessage": ["  Merge  ", "  indented"],
              "commitMessage": ["  Commit ", "  - indented", "", "Other"]
            }
          }
          ''');

        expect(entries[0].mergeMessage, 'Merge\n  indented');
        expect(entries[0].commitMessage!.firstLine, 'Commit');
        // Details keep their indentation, like a message typed on the
        // terminal; blank lines are separators.
        expect(entries[0].commitMessage!.details, ['  - indented', 'Other']);
      });

      test('ignores a field that is not on the sheet', () {
        final entries = sheet().parse('''
          {"ui": {"versionIncrement": "major", "commitMessage": ["x"]}}
          ''');
        expect(entries[1].versionIncrement, isNull);
        expect(entries[1].commitMessage, isNull);
      });

      group('throws', () {
        void expectError(String text, String message) => expect(
          () => sheet().parse(text),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains(message),
            ),
          ),
        );

        test('for invalid JSON, saying where', () {
          expectError('{"core": ', 'The file is no valid JSON');
          // The comments before the error are counted along.
          expectError(
            '/* a\n   b */ {\r\n  // c\n  "core": {"mergeMessage": x}\n}',
            'The file is no valid JSON at line 4, column 28: ',
          );
        });

        test('for an empty file', () {
          expectError('', 'The file is no valid JSON at line 1, column 1');
        });

        test('for something else than an object', () {
          expectError('[]', 'must contain one JSON object');
        });

        test('for an unknown repository', () {
          expectError(
            '{"cor": {}}',
            'Unknown repository "cor". Expected one of core, ui.',
          );
        });

        test('for an unknown field, naming the fields on the sheet', () {
          expectError(
            '{"core": {"mergMessage": ["x"]}}',
            'core: unknown field "mergMessage". Expected one of '
                'versionIncrement, mergeMessage, commitMessage.',
          );
          expectError(
            '{"ui": {"message": "x"}}',
            'ui: unknown field "message". Expected one of mergeMessage.',
          );
          expect(
            () =>
                MessageSheet(entries: const [MessageSheetEntry(repo: 'empty')])
                    .parse('{"empty": {"x": 1}}'),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                'empty: unknown field "x". Expected one of '
                    'versionIncrement, mergeMessage, commitMessage.',
              ),
            ),
          );
        });

        test('for a repository that is no object', () {
          expectError('{"core": "x"}', 'core must be a JSON object.');
        });

        test('for an unknown version increment', () {
          expectError(
            '{"core": {"versionIncrement": "huge"}}',
            'core: "versionIncrement" must be "patch", "minor" or "major".',
          );
          expectError(
            '{"core": {"versionIncrement": 1}}',
            '"versionIncrement" must be',
          );
        });

        test('for a message that is no list of strings', () {
          expectError(
            '{"core": {"mergeMessage": [1]}}',
            'core: "mergeMessage" must be a list of strings.',
          );
          expectError(
            '{"core": {"commitMessage": {}}}',
            'core: "commitMessage" must be a list of strings.',
          );
        });
      });
    });

    // #########################################################################
    group('edit()', () {
      late List<String> shown;

      EditText answering(List<String?> answers) =>
          ({required prompt, required text, required fileName}) async {
            shown.add(text);
            expect(prompt, 'gg do commit');
            expect(fileName, 'messages.jsonc');
            return answers.removeAt(0);
          };

      setUp(() => shown = []);

      Future<List<MessageSheetEntry>?> edit(List<String?> answers) =>
          sheet().edit(
            title: 'gg do commit',
            fileName: 'messages.jsonc',
            editText: answering(answers),
          );

      test('returns the edited entries', () async {
        final entries = await edit(['{"ui": {"mergeMessage": ["New"]}}']);
        expect(entries![1].mergeMessage, 'New');
        expect(shown.single, sheet().render(title: 'gg do commit'));
      });

      test('returns null when no editor can be opened', () async {
        expect(await edit([null]), isNull);
      });

      test('opens the sheet again, headed by the reason', () async {
        final entries = await edit([
          '{"core": {"versionIncrement": "huge"}}',
          '${MessageSheet.errorPrefix}old\n{"core": {"versionIncrement": "x"}}',
          '{}',
        ]);

        expect(entries, isNotNull);
        expect(shown[1], startsWith('${MessageSheet.errorPrefix}core:'));
        // An earlier reason is replaced, not stacked.
        expect(
          shown[2]
              .split('\n')
              .where((l) => l.startsWith(MessageSheet.errorPrefix)),
          hasLength(1),
        );
      });

      test('gives up when the sheet is closed again unchanged', () async {
        late String second;
        await expectLater(
          sheet().edit(
            title: 'gg do commit',
            fileName: 'messages.jsonc',
            editText:
                ({required prompt, required text, required fileName}) async {
                  if (shown.isEmpty) {
                    shown.add(text);
                    return '{"x": {}}';
                  }
                  second = text;
                  return text;
                },
          ),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('The messages were not saved: Unknown repository "x"'),
            ),
          ),
        );
        expect(second, startsWith(MessageSheet.errorPrefix));
      });

      test('gives up also when the editor only changed white space', () async {
        await expectLater(
          sheet().edit(
            title: 'gg do commit',
            fileName: 'messages.jsonc',
            editText:
                ({required prompt, required text, required fileName}) async {
                  shown.add(text);
                  if (shown.length == 1) {
                    return '{"x": {}}\r\n';
                  }
                  // CRLF line ends, white space at line ends, a last line.
                  return '${text.split('\n').join('  \r\n')}\r\n\r\n';
                },
          ),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('The messages were not saved: Unknown repository "x"'),
            ),
          ),
        );
        expect(shown, hasLength(2));
        // The reason heads the sheet with the line ends gg writes.
        expect(shown[1], isNot(contains('\r')));
      });

      test('cancels at once when the file was emptied', () async {
        await expectLater(
          edit([' \r\n ']),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('Cancelled: messages.jsonc was saved empty.'),
            ),
          ),
        );
        expect(shown, hasLength(1));
      });
    });

    // #########################################################################
    group('round trip', () {
      // Characters that JSON escapes or that look like JSONC syntax.
      final tricky = MessageSheetEntry(
        repo: 'tricky',
        versionIncrement: VersionIncrement.major,
        mergeMessage:
            'Quote " and \\ end\\\n'
            r'Path C:\dir\ // no comment'
            '\n/* not */ either,]\n'
            'Ümlaut ✓ 日本 */',
        commitMessage: CommitMessage(
          firstLine: 'Fix "x" // y',
          details: ['  - indented /* z */', r'ends with \', 'ä,]'],
        ),
        baseline: Version(0, 1, 0),
      );

      void expectSame(MessageSheetEntry actual, MessageSheetEntry expected) {
        expect(actual.repo, expected.repo);
        expect(actual.versionIncrement, expected.versionIncrement);
        expect(actual.mergeMessage, expected.mergeMessage);
        expect(
          actual.commitMessage?.firstLine,
          expected.commitMessage?.firstLine,
        );
        expect(actual.commitMessage?.details, expected.commitMessage?.details);
        expect(actual.baseline, expected.baseline);
      }

      test('gives back exactly what was rendered', () {
        final all = MessageSheet(entries: [core, ui, tricky]);
        final parsed = all.parse(all.render(title: 't'));
        expectSame(parsed[0], core);
        expectSame(parsed[1], ui);
        expectSame(parsed[2], tricky);
      });

      test('reads a file saved with CRLF line ends', () {
        final all = MessageSheet(entries: [tricky]);
        final text = all.render(title: 't').replaceAll('\n', '\r\n');
        expectSame(all.parse(text).single, tricky);
      });
    });
  });
}
