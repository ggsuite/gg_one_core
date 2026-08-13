// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_one_core/gg_one_core.dart';
import 'package:test/test.dart';

void main() {
  group('CommitMessage', () {
    group('parse()', () {
      test('takes the first non-empty line as firstLine', () {
        final message = CommitMessage.parse('  Add tracking  ');
        expect(message.firstLine, 'Add tracking');
        expect(message.details, isEmpty);
      });

      test('turns the remaining non-empty lines into details', () {
        final message = CommitMessage.parse(
          'Add tracking\n\nDetail 0\nDetail 1\n\n',
        );
        expect(message.firstLine, 'Add tracking');
        expect(message.details, ['Detail 0', 'Detail 1']);
      });

      test('yields an empty firstLine for blank input', () {
        expect(CommitMessage.parse('   \n\n  ').firstLine, isEmpty);
      });
    });

    group('validationError()', () {
      test('rejects an empty first line', () {
        expect(CommitMessage.validationError('  '), contains('not be empty'));
      });

      test('accepts exactly 60 characters', () {
        expect(CommitMessage.validationError('a' * 60), isNull);
      });

      test('rejects 61 characters and names the length', () {
        final error = CommitMessage.validationError('a' * 61);
        expect(error, contains('60 characters'));
        expect(error, contains('was 61'));
      });
    });

    group('text', () {
      test('is the first line alone without details', () {
        expect(CommitMessage(firstLine: 'Add tracking').text, 'Add tracking');
      });

      test('separates details by a blank line', () {
        expect(
          CommitMessage(firstLine: 'Add', details: ['a', 'b']).text,
          'Add\n\na\nb',
        );
      });
    });

    group('toJson()', () {
      test('omits empty details', () {
        expect(CommitMessage(firstLine: 'Add').toJson(), {'firstLine': 'Add'});
      });

      test('writes details when present', () {
        expect(CommitMessage(firstLine: 'Add', details: ['a']).toJson(), {
          'firstLine': 'Add',
          'details': ['a'],
        });
      });
    });

    group('fromJson()', () {
      test('reads first line and details', () {
        final message = CommitMessage.fromJson({
          'firstLine': ' Add ',
          'details': [' a ', '  ', 'b'],
        }, where: 'w');
        expect(message.firstLine, 'Add');
        // Blank entries are dropped, the rest trimmed.
        expect(message.details, ['a', 'b']);
      });

      test('accepts a missing details list', () {
        expect(
          CommitMessage.fromJson({'firstLine': 'Add'}, where: 'w').details,
          isEmpty,
        );
      });

      test('throws when firstLine is not a string', () {
        expect(
          () => CommitMessage.fromJson({'firstLine': 1}, where: 'w'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"firstLine" must be a string'),
            ),
          ),
        );
      });

      test('throws when firstLine is too long', () {
        expect(
          () => CommitMessage.fromJson({'firstLine': 'a' * 61}, where: 'w'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('60 characters'),
            ),
          ),
        );
      });

      test('throws when details is not a list', () {
        expect(
          () => CommitMessage.fromJson({
            'firstLine': 'Add',
            'details': 'a',
          }, where: 'w'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"details" must be a list'),
            ),
          ),
        );
      });

      test('throws when a details entry is not a string', () {
        expect(
          () => CommitMessage.fromJson({
            'firstLine': 'Add',
            'details': [1],
          }, where: 'w'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('entries must be strings'),
            ),
          ),
        );
      });
    });

    test('maxCommitMessageFirstLineLength is 60', () {
      expect(maxCommitMessageFirstLineLength, 60);
    });
  });
}
