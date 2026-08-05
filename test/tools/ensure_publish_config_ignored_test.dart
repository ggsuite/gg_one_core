// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_git/gg_git_test_helpers.dart';
import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart';
import 'package:test/test.dart';

class _MockProcessWrapper extends Mock implements GgProcessWrapper {}

void main() {
  final messages = <String>[];
  final ggLog = messages.add;
  late Directory d;

  setUpAll(() {
    registerFallbackValue(Directory.systemTemp);
  });

  setUp(() async {
    messages.clear();
    d = await Directory.systemTemp.createTemp('ensure_ignored_');
    await initLocalGit(d);
    await enableEolLf(d);
    await addAndCommitSampleFile(d, fileName: 'file.txt', content: 'x');
  });

  tearDown(() async {
    await d.delete(recursive: true);
  });

  Future<String> gitStatus() async {
    final result = await Process.run('git', [
      'status',
      '--porcelain',
    ], workingDirectory: d.path);
    return (result.stdout as String).trim();
  }

  Future<String> headMessage() async {
    final result = await Process.run('git', [
      'log',
      '-1',
      '--format=%s',
    ], workingDirectory: d.path);
    return (result.stdout as String).trim();
  }

  group('EnsurePublishConfigIgnored', () {
    test('creates .gitignore with the entries and commits it', () async {
      // The bare constructor also exercises the default GgState +
      // GgProcessWrapper dependencies.
      final ensure = EnsurePublishConfigIgnored(ggLog: ggLog);

      final changed = await ensure.ensure(directory: d);

      expect(changed, isTrue);
      final content = File(join(d.path, '.gitignore')).readAsStringSync();
      expect(
        content,
        '.gg/gg-publish.json\n'
        '.gg/pubspec_overrides_backup.yaml\n'
        '.gg/pnpm_workspace_backup.yaml\n',
      );
      // The change was committed — the working tree is clean again.
      expect(await gitStatus(), isEmpty);
      expect(await headMessage(), contains('Ignore the publish runtime files'));
      expect(
        messages,
        contains(
          'Added .gg/gg-publish.json, .gg/pubspec_overrides_backup.yaml, '
          '.gg/pnpm_workspace_backup.yaml to .gitignore.',
        ),
      );
    });

    test(
      'appends to an existing .gitignore without a trailing newline',
      () async {
        final gitignore = File(join(d.path, '.gitignore'));
        gitignore.writeAsStringSync('build/'); // no trailing newline
        await commitFile(d, '.gitignore');

        final ensure = EnsurePublishConfigIgnored(ggLog: ggLog);
        final changed = await ensure.ensure(directory: d);

        expect(changed, isTrue);
        expect(
          gitignore.readAsStringSync(),
          'build/\n'
          '.gg/gg-publish.json\n'
          '.gg/pubspec_overrides_backup.yaml\n'
          '.gg/pnpm_workspace_backup.yaml\n',
        );
        expect(await gitStatus(), isEmpty);
      },
    );

    test('appends only the entries that are missing', () async {
      final gitignore = File(join(d.path, '.gitignore'));
      gitignore.writeAsStringSync('.gg/gg-publish.json\n');
      await commitFile(d, '.gitignore');

      final ensure = EnsurePublishConfigIgnored(ggLog: ggLog);
      final changed = await ensure.ensure(directory: d);

      expect(changed, isTrue);
      expect(
        gitignore.readAsStringSync(),
        '.gg/gg-publish.json\n'
        '.gg/pubspec_overrides_backup.yaml\n'
        '.gg/pnpm_workspace_backup.yaml\n',
      );
    });

    test('is a no-op when the entries are already present', () async {
      final ensure = EnsurePublishConfigIgnored(ggLog: ggLog);
      await ensure.ensure(directory: d);
      final headBefore = await headMessage();

      final changedAgain = await ensure.ensure(directory: d);

      expect(changedAgain, isFalse);
      // No further commit happened.
      expect(await headMessage(), headBefore);
    });

    test('commit: false leaves the change uncommitted', () async {
      final ensure = EnsurePublishConfigIgnored(ggLog: ggLog);

      final changed = await ensure.ensure(directory: d, commit: false);

      expect(changed, isTrue);
      expect(await gitStatus(), contains('.gitignore'));
    });

    test('heals a repository whose .gitignore ignores the whole '
        '.gg folder', () async {
      // The state this bootstrap used to crash on: a directory-wide
      // ».gg/« rule plus a state file written by an earlier check run.
      final gitignore = File(join(d.path, '.gitignore'));
      gitignore.writeAsStringSync('.gg/\n');
      await commitFile(d, '.gitignore');
      File(join(d.path, '.gg', 'gg.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{}');

      final ensure = EnsurePublishConfigIgnored(ggLog: ggLog);
      final changed = await ensure.ensure(directory: d);

      expect(changed, isTrue);
      expect(
        gitignore.readAsStringSync(),
        '.gg/*\n'
        '!.gg/gg.json\n'
        '.gg/gg-publish.json\n'
        '.gg/pubspec_overrides_backup.yaml\n'
        '.gg/pnpm_workspace_backup.yaml\n',
      );

      // Two commits: the heal, then the entries bootstrap — and the
      // working tree is clean afterwards.
      final log = await Process.run('git', [
        'log',
        '-2',
        '--format=%s',
      ], workingDirectory: d.path);
      expect((log.stdout as String).trim().split('\n'), [
        '#gg: Ignore the publish runtime files of gg',
        '#gg: Stop ignoring .gg/gg.json',
      ]);
      expect(await gitStatus(), isEmpty);
    });

    test('transplants recorded check hashes onto the new content', () async {
      // Record a check success for the current content …
      final state = GgState(ggLog: ggLog);
      await state.writeSuccess(directory: d, key: 'canCommit');
      expect(
        await state.readSuccess(directory: d, key: 'canCommit', ggLog: ggLog),
        isTrue,
      );

      // … then change the content by adding the .gitignore entry.
      await EnsurePublishConfigIgnored(ggLog: ggLog).ensure(directory: d);

      // The success survives because the hash was transplanted.
      expect(
        await state.readSuccess(directory: d, key: 'canCommit', ggLog: ggLog),
        isTrue,
      );
    });

    group('throws', () {
      late MockGgState state;
      late _MockProcessWrapper processWrapper;

      setUp(() {
        state = MockGgState();
        processWrapper = _MockProcessWrapper();
        when(
          () => state.currentHash(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async => 123);
        when(
          () => state.updateHash(
            hash: any(named: 'hash'),
            directory: any(named: 'directory'),
          ),
        ).thenAnswer((_) async {});

        // The gg.json guard runs first — report the state file as visible.
        when(
          () => processWrapper.run(
            'git',
            any(that: contains('check-ignore')),
            workingDirectory: any(named: 'workingDirectory'),
          ),
        ).thenAnswer((_) async => ProcessResult(0, 1, '', ''));
      });

      test('when git add fails', () async {
        when(
          () => processWrapper.run(
            'git',
            any(that: contains('add')),
            workingDirectory: any(named: 'workingDirectory'),
          ),
        ).thenAnswer((_) async => ProcessResult(0, 1, '', 'add broken'));

        final ensure = EnsurePublishConfigIgnored(
          ggLog: ggLog,
          state: state,
          processWrapper: processWrapper,
        );
        await expectLater(
          () => ensure.ensure(directory: d),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              contains('git add'),
            ),
          ),
        );
      });

      test('when git commit fails', () async {
        when(
          () => processWrapper.run(
            'git',
            any(that: contains('add')),
            workingDirectory: any(named: 'workingDirectory'),
          ),
        ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
        when(
          () => processWrapper.run(
            'git',
            any(that: contains('commit')),
            workingDirectory: any(named: 'workingDirectory'),
          ),
        ).thenAnswer((_) async => ProcessResult(0, 1, '', 'commit broken'));

        final ensure = EnsurePublishConfigIgnored(
          ggLog: ggLog,
          state: state,
          processWrapper: processWrapper,
        );
        await expectLater(
          () => ensure.ensure(directory: d),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              contains('Committing the .gitignore entry'),
            ),
          ),
        );
      });
    });
  });
}
