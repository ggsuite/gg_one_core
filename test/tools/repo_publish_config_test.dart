// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_publish/gg_publish.dart';
import 'package:path/path.dart';
import 'package:test/test.dart';

void main() {
  late Directory d;

  setUp(() async {
    d = await Directory.systemTemp.createTemp('repo_publish_config_');
  });

  tearDown(() async {
    await d.delete(recursive: true);
  });

  RepoPublishConfig parse(String raw) =>
      RepoPublishConfig.fromJsonString(raw, where: 'w');

  group('repoPublishConfigFile()', () {
    test('points at <repo>/.gg/publish_config.json', () {
      expect(
        repoPublishConfigFile(d).path,
        join(d.path, '.gg', 'publish_config.json'),
      );
    });
  });

  group('RepoPublishConfig', () {
    group('fromJsonString()', () {
      test('reads every field', () {
        final config = parse('''
{
  "publishConfig": {
    "mergeMessage": " Add tracking ",
    "versionIncrement": "minor",
    "nextCommitMessage": {"firstLine": "Next", "details": ["d"]},
    "commits": [{"firstLine": "Done"}]
  }
}
''');
        expect(config.mergeMessage, 'Add tracking');
        expect(config.versionIncrement, VersionIncrement.minor);
        expect(config.nextCommitMessage?.firstLine, 'Next');
        expect(config.nextCommitMessage?.details, ['d']);
        expect(config.commits.single.firstLine, 'Done');
      });

      test('accepts an empty publishConfig object', () {
        final config = parse('{"publishConfig": {}}');
        expect(config.mergeMessage, isNull);
        expect(config.versionIncrement, isNull);
        expect(config.nextCommitMessage, isNull);
        expect(config.commits, isEmpty);
      });

      test('treats a blank mergeMessage as absent', () {
        expect(
          parse('{"publishConfig":{"mergeMessage":"  "}}').mergeMessage,
          isNull,
        );
      });

      test('throws on invalid JSON', () {
        expect(
          () => parse('{'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('is not valid JSON'),
            ),
          ),
        );
      });

      test('throws when the top level is not an object', () {
        expect(
          () => parse('[]'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('must contain a JSON object'),
            ),
          ),
        );
      });

      test('throws when the publishConfig wrapper is missing', () {
        expect(
          () => parse('{}'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"publishConfig" must be a JSON object'),
            ),
          ),
        );
      });

      test('throws on an unknown versionIncrement', () {
        expect(
          () => parse('{"publishConfig":{"versionIncrement":"huge"}}'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"versionIncrement" must be one of'),
            ),
          ),
        );
      });

      test('throws when mergeMessage is not a string', () {
        expect(
          () => parse('{"publishConfig":{"mergeMessage":1}}'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"mergeMessage" must be a string'),
            ),
          ),
        );
      });

      test('throws when nextCommitMessage is not an object', () {
        expect(
          () => parse('{"publishConfig":{"nextCommitMessage":[]}}'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"nextCommitMessage" must be a JSON object'),
            ),
          ),
        );
      });

      test('throws when commits is not a list', () {
        expect(
          () => parse('{"publishConfig":{"commits":{}}}'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"commits" must be a list'),
            ),
          ),
        );
      });

      test('throws when a commits entry is not an object', () {
        expect(
          () => parse('{"publishConfig":{"commits":[1]}}'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"commits[0]" must be a JSON object'),
            ),
          ),
        );
      });
    });

    group('tryLoad()', () {
      test('returns null when the file is missing', () {
        expect(RepoPublishConfig.tryLoad(d), isNull);
      });

      test('reads a written file back', () async {
        await RepoPublishConfig(
          mergeMessage: 'Add tracking',
          versionIncrement: VersionIncrement.major,
        ).save(file: repoPublishConfigFile(d));

        final reloaded = RepoPublishConfig.tryLoad(d)!;
        expect(reloaded.mergeMessage, 'Add tracking');
        expect(reloaded.versionIncrement, VersionIncrement.major);
      });
    });

    group('toJson()', () {
      test('omits everything that is empty', () {
        expect(RepoPublishConfig().toJson(), {
          'publishConfig': <String, dynamic>{},
        });
      });

      test('wraps the content in publishConfig', () {
        final json = RepoPublishConfig(
          mergeMessage: 'm',
          versionIncrement: VersionIncrement.patch,
          nextCommitMessage: CommitMessage(firstLine: 'Next'),
          commits: [CommitMessage(firstLine: 'Done')],
        ).toJson();

        expect(json, {
          'publishConfig': {
            'mergeMessage': 'm',
            'versionIncrement': 'patch',
            'nextCommitMessage': {'firstLine': 'Next'},
            'commits': [
              {'firstLine': 'Done'},
            ],
          },
        });
      });
    });

    group('withCommitted()', () {
      test('appends the message and keeps nextCommitMessage', () {
        final next = CommitMessage(firstLine: 'Next');
        final config = RepoPublishConfig(nextCommitMessage: next);

        final updated = config.withCommitted(next);

        expect(updated.commits.single.firstLine, 'Next');
        // The proposal is not consumed — the AI keeps it up to date.
        expect(updated.nextCommitMessage?.firstLine, 'Next');
      });

      test('does not append a deep-equal message twice', () {
        final message = CommitMessage(firstLine: 'Next', details: ['a']);
        final once = RepoPublishConfig().withCommitted(message);

        final twice = once.withCommitted(
          CommitMessage(firstLine: 'Next', details: ['a']),
        );

        expect(twice.commits, hasLength(1));
        expect(identical(twice, once), isTrue);
      });

      test('appends when a detail changed', () {
        final once = RepoPublishConfig().withCommitted(
          CommitMessage(firstLine: 'Next'),
        );

        final twice = once.withCommitted(
          CommitMessage(firstLine: 'Next', details: ['a']),
        );

        expect(twice.commits, hasLength(2));
      });
    });

    group('copyWith()', () {
      test('keeps the current values by default', () {
        final config = RepoPublishConfig(
          mergeMessage: 'm',
          versionIncrement: VersionIncrement.minor,
          nextCommitMessage: CommitMessage(firstLine: 'Next'),
          commits: [CommitMessage(firstLine: 'Done')],
        );

        final copy = config.copyWith();

        expect(copy.mergeMessage, 'm');
        expect(copy.versionIncrement, VersionIncrement.minor);
        expect(copy.nextCommitMessage?.firstLine, 'Next');
        expect(copy.commits.single.firstLine, 'Done');
      });

      test('replaces the given values', () {
        final copy = RepoPublishConfig(mergeMessage: 'm').copyWith(
          mergeMessage: 'n',
          versionIncrement: VersionIncrement.major,
          nextCommitMessage: CommitMessage(firstLine: 'N'),
          commits: [CommitMessage(firstLine: 'D')],
        );

        expect(copy.mergeMessage, 'n');
        expect(copy.versionIncrement, VersionIncrement.major);
        expect(copy.nextCommitMessage?.firstLine, 'N');
        expect(copy.commits.single.firstLine, 'D');
      });

      test('clearNextCommitMessage removes the proposal', () {
        final copy = RepoPublishConfig(
          nextCommitMessage: CommitMessage(firstLine: 'N'),
        ).copyWith(clearNextCommitMessage: true);

        expect(copy.nextCommitMessage, isNull);
      });
    });

    group('pullRequestBody', () {
      test('is null without commits', () {
        expect(RepoPublishConfig().pullRequestBody, isNull);
      });

      test('renders one bullet per commit with indented details', () {
        final config = RepoPublishConfig(
          commits: [
            CommitMessage(firstLine: 'Add tracking', details: ['a', 'b']),
            CommitMessage(firstLine: 'Fix typo'),
          ],
        );

        expect(
          config.pullRequestBody,
          '- Add tracking\n'
          '  - a\n'
          '  - b\n'
          '- Fix typo',
        );
      });
    });
  });
}
