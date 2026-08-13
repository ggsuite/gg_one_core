// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_git/gg_git.dart';
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
    d = await Directory.systemTemp.createTemp('ensure_gg_json_');
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

  Future<List<String>> headFiles() async {
    final result = await Process.run('git', [
      'show',
      '--name-only',
      '--format=',
    ], workingDirectory: d.path);
    return (result.stdout as String)
        .trim()
        .split('\n')
        .where((line) => line.isNotEmpty)
        .toList();
  }

  Future<bool> isIgnored() async {
    final result = await Process.run('git', [
      'check-ignore',
      '--quiet',
      '--',
      '.gg/gg.json',
    ], workingDirectory: d.path);
    return result.exitCode == 0;
  }

  File gitignore() => File(join(d.path, '.gitignore'));

  Future<void> commitGitignore(String content) async {
    gitignore().writeAsStringSync(content);
    await commitFile(d, '.gitignore');
  }

  void writeGgJson() {
    File(join(d.path, '.gg', 'gg.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
  }

  group('EnsureGgJsonNotIgnored', () {
    group('is a no-op', () {
      test('when nothing ignores .gg/gg.json', () async {
        // The bare constructor also exercises the default GgState +
        // GgProcessWrapper dependencies.
        final guard = EnsureGgJsonNotIgnored(ggLog: ggLog);
        final headBefore = await headMessage();

        expect(await guard.ensure(directory: d), isFalse);

        expect(gitignore().existsSync(), isFalse);
        expect(await headMessage(), headBefore);
        expect(messages, isEmpty);

        // The second call is answered from the per-process memo.
        expect(await guard.ensure(directory: d), isFalse);
      });

      test('outside a git repository', () async {
        final noRepo = await Directory.systemTemp.createTemp('no_repo_');
        addTearDown(() => noRepo.delete(recursive: true));

        final guard = EnsureGgJsonNotIgnored(ggLog: ggLog);
        expect(await guard.ensure(directory: noRepo), isFalse);
      });
    });

    group('rewrites the rule to ».gg/*« + »!.gg/gg.json«', () {
      for (final pattern in ['.gg', '.gg/', '/.gg', '/.gg/']) {
        test('for a directory rule »$pattern«', () async {
          await commitGitignore('coverage\n$pattern\nbuild/\n');
          writeGgJson();

          final changed = await EnsureGgJsonNotIgnored(ggLog: ggLog)
              .ensure(directory: d);

          expect(changed, isTrue);
          expect(
            gitignore().readAsStringSync(),
            'coverage\n.gg/*\n!.gg/gg.json\nbuild/\n',
          );
          expect(await isIgnored(), isFalse);

          // The fix was committed together with the now trackable state
          // file — the working tree is clean again.
          expect(await gitStatus(), isEmpty);
          expect(await headMessage(), '#gg: Stop ignoring .gg/gg.json');
          expect(await headFiles(), ['.gg/gg.json', '.gitignore']);
          expect(
            messages,
            contains('Rewrote .gitignore: .gg/gg.json must not be ignored.'),
          );
        });
      }

      test('resolving duplicates of the rule in the same pass', () async {
        await commitGitignore('.gg/\n.gg/\n');

        final changed = await EnsureGgJsonNotIgnored(ggLog: ggLog)
            .ensure(directory: d);

        expect(changed, isTrue);
        expect(gitignore().readAsStringSync(), '.gg/*\n!.gg/gg.json\n');
        expect(await gitStatus(), isEmpty);
      });

      test('committing .gitignore alone when no .gg/gg.json exists '
          'yet', () async {
        await commitGitignore('.gg/\n');

        final changed = await EnsureGgJsonNotIgnored(ggLog: ggLog)
            .ensure(directory: d);

        expect(changed, isTrue);
        expect(await headFiles(), ['.gitignore']);
        expect(await gitStatus(), isEmpty);
      });
    });

    test('adds the missing negation after an existing ».gg/*« rule', () async {
      await commitGitignore('.gg/*\n');

      final changed = await EnsureGgJsonNotIgnored(ggLog: ggLog)
          .ensure(directory: d);

      expect(changed, isTrue);
      expect(gitignore().readAsStringSync(), '.gg/*\n!.gg/gg.json\n');
      expect(await isIgnored(), isFalse);
    });

    test('drops a literal ».gg/gg.json« rule', () async {
      await commitGitignore('.gg/gg.json\n.gg/gg.json\n');

      final changed = await EnsureGgJsonNotIgnored(ggLog: ggLog)
          .ensure(directory: d);

      expect(changed, isTrue);
      expect(gitignore().readAsStringSync(), '');
      expect(await isIgnored(), isFalse);
    });

    test('rewrites one rule per round until the file is visible', () async {
      // The literal rule decides and hides the directory rule above it —
      // the fix must peel both away.
      await commitGitignore('.gg/\n.gg/gg.json\n');

      final changed = await EnsureGgJsonNotIgnored(ggLog: ggLog)
          .ensure(directory: d);

      expect(changed, isTrue);
      expect(gitignore().readAsStringSync(), '.gg/*\n!.gg/gg.json\n');
      expect(await isIgnored(), isFalse);
      expect(await gitStatus(), isEmpty);
    });

    test('transplants recorded check hashes onto the new content', () async {
      await commitGitignore('.gg/\n');

      // Record a check success for the current content by hand — the state
      // file is still invisible to git at this point.
      final hash = await LastChangesHash(ggLog: ggLog)
          .get(directory: d, ggLog: ggLog);
      File(join(d.path, '.gg', 'gg.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"canCommit":{"success":{"hash":$hash}}}');

      final state = GgState(ggLog: ggLog);
      expect(
        await state.readSuccess(directory: d, key: 'canCommit', ggLog: ggLog),
        isTrue,
      );

      // The fix changes .gitignore — the success must survive it.
      await EnsureGgJsonNotIgnored(ggLog: ggLog).ensure(directory: d);

      expect(
        await state.readSuccess(directory: d, key: 'canCommit', ggLog: ggLog),
        isTrue,
      );
    });

    group('throws', () {
      test('for a rule it cannot rewrite safely', () async {
        await commitGitignore('.g*\n');

        await expectLater(
          () => EnsureGgJsonNotIgnored(ggLog: ggLog).ensure(directory: d),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              allOf(
                contains('The rule ».g*« in .gitignore:1'),
                contains('.gg/gg.json must not be git-ignored'),
                contains('!.gg/gg.json'),
              ),
            ),
          ),
        );

        // Nothing was changed or committed.
        expect(gitignore().readAsStringSync(), '.g*\n');
        expect(await gitStatus(), isEmpty);
      });

      test('for a rule outside the repository root .gitignore', () async {
        File(join(d.path, '.git', 'info', 'exclude'))
            .writeAsStringSync('.gg/\n');

        await expectLater(
          () => EnsureGgJsonNotIgnored(ggLog: ggLog).ensure(directory: d),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              contains('.git/info/exclude'),
            ),
          ),
        );
      });

      group('with mocked git', () {
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

          // .gg/gg.json is reported as ignored exactly once — after the
          // rewrite the loop sees a visible file again.
          var quietCalls = 0;
          when(
            () => processWrapper.run(
              'git',
              any(that: contains('--quiet')),
              workingDirectory: any(named: 'workingDirectory'),
            ),
          ).thenAnswer(
            (_) async => ProcessResult(0, quietCalls++ == 0 ? 0 : 1, '', ''),
          );
          when(
            () => processWrapper.run(
              'git',
              any(that: contains('--verbose')),
              workingDirectory: any(named: 'workingDirectory'),
            ),
          ).thenAnswer(
            (_) async =>
                ProcessResult(0, 0, '.gitignore:1:.gg/\t.gg/gg.json\n', ''),
          );

          gitignore().writeAsStringSync('.gg/\n');
        });

        test('when git add fails', () async {
          when(
            () => processWrapper.run(
              'git',
              any(that: contains('add')),
              workingDirectory: any(named: 'workingDirectory'),
            ),
          ).thenAnswer((_) async => ProcessResult(0, 1, '', 'add broken'));

          final guard = EnsureGgJsonNotIgnored(
            ggLog: ggLog,
            state: state,
            processWrapper: processWrapper,
          );
          await expectLater(
            () => guard.ensure(directory: d),
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

          final guard = EnsureGgJsonNotIgnored(
            ggLog: ggLog,
            state: state,
            processWrapper: processWrapper,
          );
          await expectLater(
            () => guard.ensure(directory: d),
            throwsA(
              isA<Exception>().having(
                (e) => rmControls(e.toString()),
                'message',
                contains('Committing the .gitignore fix failed'),
              ),
            ),
          );
        });

        test('when the offending rule cannot be read', () async {
          // Keep reporting the file as ignored — the loop must reach the
          // verbose lookup, whose result is unparsable here.
          when(
            () => processWrapper.run(
              'git',
              any(that: contains('--quiet')),
              workingDirectory: any(named: 'workingDirectory'),
            ),
          ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
          when(
            () => processWrapper.run(
              'git',
              any(that: contains('--verbose')),
              workingDirectory: any(named: 'workingDirectory'),
            ),
          ).thenAnswer((_) async => ProcessResult(0, 0, 'garbage', ''));

          final guard = EnsureGgJsonNotIgnored(
            ggLog: ggLog,
            state: state,
            processWrapper: processWrapper,
          );
          await expectLater(
            () => guard.ensure(directory: d),
            throwsA(
              isA<Exception>().having(
                (e) => rmControls(e.toString()),
                'message',
                contains('.gg/gg.json must not be git-ignored'),
              ),
            ),
          );
        });
      });
    });
  });
}
