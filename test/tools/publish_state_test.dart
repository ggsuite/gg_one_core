// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_one_core/gg_one_core.dart';
import 'package:path/path.dart';
import 'package:test/test.dart';

void main() {
  late Directory d;

  setUp(() async {
    d = await Directory.systemTemp.createTemp('publish_state_');
  });

  tearDown(() async {
    await d.delete(recursive: true);
  });

  PublishState parse(String raw) =>
      PublishState.fromJsonString(raw, where: 'w');

  group('publishStateFile()', () {
    test('points at <dir>/.gg/publish_state.json', () {
      expect(
        publishStateFile(d).path,
        join(d.path, '.gg', 'publish_state.json'),
      );
    });
  });

  group('PublishState', () {
    group('fromJsonString()', () {
      test('reads every field', () {
        final state = parse('''
{
  "status": "pending",
  "doneSteps": ["prepare_version", "merge"],
  "branch": "feature",
  "pr": true,
  "channel": "rc",
  "deleteTicket": false,
  "deleteFeatureBranch": true
}
''');
        expect(state.status, 'pending');
        expect(state.doneSteps, ['prepare_version', 'merge']);
        expect(state.branch, 'feature');
        expect(state.pr, isTrue);
        expect(state.channel, 'rc');
        expect(state.deleteTicket, isFalse);
        expect(state.deleteFeatureBranch, isTrue);
      });

      test('reads an empty object', () {
        final state = parse('{}');
        expect(state.status, isNull);
        expect(state.doneSteps, isEmpty);
        expect(state.branch, isNull);
        expect(state.pr, isNull);
        expect(state.channel, isNull);
        expect(state.deleteTicket, isNull);
        expect(state.deleteFeatureBranch, isNull);
      });

      test('drops duplicate steps', () {
        expect(parse('{"doneSteps":["merge","merge"]}').doneSteps, ['merge']);
      });

      test('accepts the legacy registry step', () {
        final state = parse('{"doneSteps":["publish_registry"]}');
        expect(state.hasLegacyRegistryStep, isTrue);
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

      test('throws on an unknown status', () {
        expect(
          () => parse('{"status":"weird"}'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"status" must be one of'),
            ),
          ),
        );
      });

      test('throws on an unknown channel', () {
        expect(
          () => parse('{"channel":"nightly"}'),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws when doneSteps is not a list', () {
        expect(
          () => parse('{"doneSteps":"merge"}'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"doneSteps" must be a list'),
            ),
          ),
        );
      });

      test('throws on an unknown step', () {
        expect(
          () => parse('{"doneSteps":["dance"]}'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"doneSteps" entries must be one of'),
            ),
          ),
        );
      });

      test('throws when a string field has the wrong type', () {
        expect(() => parse('{"branch":1}'), throwsA(isA<FormatException>()));
      });

      test('throws when a string field is empty', () {
        expect(() => parse('{"branch":""}'), throwsA(isA<FormatException>()));
      });

      test('throws when a boolean field has the wrong type', () {
        expect(() => parse('{"pr":"yes"}'), throwsA(isA<FormatException>()));
      });
    });

    group('tryLoad()', () {
      test('returns null when the file is missing', () {
        expect(PublishState.tryLoad(d), isNull);
      });

      test('reads a written file back', () async {
        await PublishState(
          status: 'published',
          doneSteps: ['merge'],
        ).save(file: publishStateFile(d));

        final reloaded = PublishState.tryLoad(d)!;
        expect(reloaded.status, 'published');
        expect(reloaded.doneSteps, ['merge']);
      });
    });

    test('toJson() omits null and empty fields', () {
      expect(PublishState().toJson(), isEmpty);
      expect(PublishState(status: 'failed').toJson(), {'status': 'failed'});
      expect(
        PublishState(
          doneSteps: ['tag'],
          branch: 'f',
          pr: false,
          channel: 'stable',
          deleteTicket: true,
          deleteFeatureBranch: false,
        ).toJson(),
        {
          'doneSteps': ['tag'],
          'branch': 'f',
          'pr': false,
          'channel': 'stable',
          'deleteTicket': true,
          'deleteFeatureBranch': false,
        },
      );
    });

    group('withStepDone()', () {
      test('appends the step', () {
        final state = PublishState().withStepDone('merge');
        expect(state.doneSteps, ['merge']);
        expect(state.isStepDone('merge'), isTrue);
        expect(state.hasStepProgress, isTrue);
      });

      test('is a no-op for an already-done step', () {
        final once = PublishState().withStepDone('merge');
        expect(identical(once.withStepDone('merge'), once), isTrue);
      });

      test('refuses a legacy step name', () {
        expect(
          () => PublishState().withStepDone('publish_registry'),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('refuses an unknown step name', () {
        expect(
          () => PublishState().withStepDone('dance'),
          throwsA(isA<ArgumentError>()),
        );
      });
    });

    group('withStatus()', () {
      test('sets the status', () {
        expect(PublishState().withStatus('skipped').status, 'skipped');
      });

      test('refuses an unknown status', () {
        expect(
          () => PublishState().withStatus('weird'),
          throwsA(isA<ArgumentError>()),
        );
      });
    });

    test('copyWith() keeps unset fields', () {
      final state = PublishState(
        status: 'pending',
        doneSteps: ['merge'],
        branch: 'f',
        pr: true,
        channel: 'rc',
        deleteTicket: true,
        deleteFeatureBranch: true,
      );

      expect(state.copyWith().toJson(), state.toJson());
      expect(state.copyWith(branch: 'g').branch, 'g');
      expect(state.copyWith(pr: false).pr, isFalse);
      expect(state.copyWith(channel: 'stable').channel, 'stable');
      expect(state.copyWith(deleteTicket: false).deleteTicket, isFalse);
      expect(
        state.copyWith(deleteFeatureBranch: false).deleteFeatureBranch,
        isFalse,
      );
    });

    test('hasLegacyRegistryStep is false without the marker', () {
      expect(PublishState().hasLegacyRegistryStep, isFalse);
    });
  });
}
