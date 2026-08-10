// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_git/gg_git_test_helpers.dart';
import 'package:gg_one_core/gg_one_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory d;
  late Directory dRemote;
  late GgSystemCommit systemCommit;
  final messages = <String>[];

  // ...........................................................................
  Future<void> run(String executable, List<String> args) async {
    final result = await Process.run(
      executable,
      args,
      workingDirectory: d.path,
    );
    if (result.exitCode != 0) {
      throw Exception('$executable ${args.join(' ')} failed: ${result.stderr}');
    }
  }

  Future<String> headSubject() async {
    final result = await Process.run('git', [
      'log',
      '-1',
      '--format=%s',
    ], workingDirectory: d.path);
    return result.stdout.toString().trim();
  }

  Future<String> subjectOf(String rev) async {
    final result = await Process.run('git', [
      'log',
      '-1',
      '--format=%s',
      rev,
    ], workingDirectory: d.path);
    return result.stdout.toString().trim();
  }

  Future<List<String>> filesOf(String rev) async {
    final result = await Process.run('git', [
      'show',
      '--name-only',
      '--format=',
      rev,
    ], workingDirectory: d.path);
    return result.stdout
        .toString()
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  Future<List<String>> dirtyFiles() async {
    final result = await Process.run('git', [
      'status',
      '--porcelain',
      '-uall',
    ], workingDirectory: d.path);
    return result.stdout
        .toString()
        .split('\n')
        .where((l) => l.length > 3)
        .map((l) => l.substring(3).trim())
        .toList();
  }

  // ...........................................................................
  setUp(() async {
    messages.clear();
    (d, dRemote) = await initLocalAndRemoteGit();
    await enableEolLf(d);
    await addAndCommitSampleFile(d, fileName: 'base.txt', content: 'base');
    await createBranch(d, 'CDM-1');
    systemCommit = GgSystemCommit(ggLog: messages.add);
  });

  tearDown(() async {
    await d.delete(recursive: true);
    await dRemote.delete(recursive: true);
  });

  group('GgSystemCommit', () {
    group('commit(directory, message, ...)', () {
      group('validates its input', () {
        test('rejects a message without the gg prefix', () async {
          await expectLater(
            systemCommit.commit(
              directory: d,
              ggLog: messages.add,
              message: 'Fix login bug',
            ),
            throwsA(isA<ArgumentError>()),
          );
        });

        test('rejects an explicit path that is not gg owned', () async {
          await expectLater(
            systemCommit.commit(
              directory: d,
              ggLog: messages.add,
              message: '#gg: Update pubspec.lock',
              paths: ['lib/user_code.dart'],
            ),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.toString(),
                'message',
                contains('lib/user_code.dart'),
              ),
            ),
          );
        });
      });

      test('does nothing on a clean tree', () async {
        final result = await systemCommit.commit(
          directory: d,
          ggLog: messages.add,
          message: '#gg: Update pubspec.lock',
        );

        expect(result.systemCommitCreated, isFalse);
        expect(result.userCommitCreated, isFalse);
        expect(await headSubject(), isNot(startsWith('#gg')));
      });

      test('commits dirty gg-owned files under the gg message', () async {
        await File('${d.path}/pubspec.lock').writeAsString('generated');
        await File('${d.path}/CHANGELOG.md').writeAsString('# Changelog');

        final result = await systemCommit.commit(
          directory: d,
          ggLog: messages.add,
          message: '#gg: Update bookkeeping',
        );

        expect(result.systemCommitCreated, isTrue);
        expect(result.userCommitCreated, isFalse);
        expect(await headSubject(), '#gg: Update bookkeeping');
        expect(
          await filesOf('HEAD'),
          containsAll(<String>['pubspec.lock', 'CHANGELOG.md']),
        );
        expect(await dirtyFiles(), isEmpty);
      });

      group('saves foreign changes first', () {
        test('as their own commit without the gg prefix', () async {
          await File('${d.path}/pubspec.lock').writeAsString('generated');
          await File('${d.path}/user_code.dart').writeAsString('user work');

          final result = await systemCommit.commit(
            directory: d,
            ggLog: messages.add,
            message: '#gg: Update bookkeeping',
            userCommitMessage: (_) => 'Improve commit behavior',
          );

          expect(result.userCommitCreated, isTrue);
          expect(result.systemCommitCreated, isTrue);
          expect(result.userCommitMessage, 'Improve commit behavior');

          // HEAD is the gg commit, HEAD~1 the user commit — the user's work
          // is visible as work, in its own commit.
          expect(await headSubject(), '#gg: Update bookkeeping');
          expect(await subjectOf('HEAD~1'), 'Improve commit behavior');
          expect(await filesOf('HEAD'), ['pubspec.lock']);
          expect(await filesOf('HEAD~1'), ['user_code.dart']);
          expect(await dirtyFiles(), isEmpty);
        });

        test('falls back to the ticket description', () async {
          // The repo sits inside a ticket folder carrying a ticket.json file.
          File('${d.path}/../ticket.json').writeAsStringSync(
            jsonEncode({'description': 'Ticket description wins'}),
          );
          addTearDown(() => File('${d.path}/../ticket.json').deleteSync());

          await File('${d.path}/user_code.dart').writeAsString('user work');

          final result = await systemCommit.commit(
            directory: d,
            ggLog: messages.add,
            message: '#gg: Update bookkeeping',
          );

          expect(result.userCommitMessage, 'Ticket description wins');
          expect(await headSubject(), 'Ticket description wins');
        });

        test('falls back to the branch name last', () async {
          await File('${d.path}/user_code.dart').writeAsString('user work');

          final result = await systemCommit.commit(
            directory: d,
            ggLog: messages.add,
            message: '#gg: Update bookkeeping',
          );

          expect(result.userCommitMessage, 'Save pending changes on CDM-1');
          expect(await headSubject(), 'Save pending changes on CDM-1');
        });

        test('rewrites a user message that looks generated', () async {
          await File('${d.path}/user_code.dart').writeAsString('user work');

          final result = await systemCommit.commit(
            directory: d,
            ggLog: messages.add,
            message: '#gg: Update bookkeeping',
            userCommitMessage: (_) => '#gg: sneaky',
          );

          // A user commit that classified as generated would be skipped by
          // the publish skip check — the work would be lost with the ticket.
          expect(
            result.userCommitMessage,
            'Save pending changes (#gg: sneaky)',
          );
        });

        test('a rename into a gg-owned name stays a user change', () async {
          await addAndCommitSampleFile(d, fileName: 'notes.md', content: 'x');
          await run('git', ['mv', 'notes.md', 'CHANGELOG.md']);

          final result = await systemCommit.commit(
            directory: d,
            ggLog: messages.add,
            message: '#gg: Update bookkeeping',
            userCommitMessage: (_) => 'Renamed my notes',
          );

          // The rename is atomic user content — both names go into the user
          // commit, none into a gg commit.
          expect(result.userCommitCreated, isTrue);
          expect(result.systemCommitCreated, isFalse);
          expect(await headSubject(), 'Renamed my notes');
        });
      });

      group('with explicit paths', () {
        test('commits only the dirty ones among them', () async {
          await File('${d.path}/pubspec.lock').writeAsString('generated');
          await File('${d.path}/CHANGELOG.md').writeAsString('# Changelog');

          final result = await systemCommit.commit(
            directory: d,
            ggLog: messages.add,
            message: '#gg: Update pubspec.lock',
            // pubspec.yaml is gg-owned but clean — it must be dropped, not
            // handed to git as a pathspec that matches nothing.
            paths: ['pubspec.lock', 'pubspec.yaml'],
          );

          expect(result.ggOwnedPaths, ['pubspec.lock']);
          expect(await filesOf('HEAD'), ['pubspec.lock']);

          // The gg-owned file outside the explicit list stays dirty.
          expect(await dirtyFiles(), ['CHANGELOG.md']);
        });

        test(
          'still saves foreign changes even when no path is dirty',
          () async {
            await File('${d.path}/user_code.dart').writeAsString('user work');

            final result = await systemCommit.commit(
              directory: d,
              ggLog: messages.add,
              message: '#gg: Update pubspec.lock',
              paths: ['pubspec.lock'],
              userCommitMessage: (_) => 'My work',
            );

            expect(result.userCommitCreated, isTrue);
            expect(result.systemCommitCreated, isFalse);
            expect(await headSubject(), 'My work');
          },
        );
      });

      group('enforces the feature branch rule', () {
        test('throws on main instead of committing', () async {
          await run('git', ['checkout', 'main']);
          await File('${d.path}/pubspec.lock').writeAsString('generated');

          await expectLater(
            systemCommit.commit(
              directory: d,
              ggLog: messages.add,
              message: '#gg: Update pubspec.lock',
            ),
            throwsA(
              isA<Exception>().having(
                (e) => e.toString(),
                'message',
                contains('branch »main«'),
              ),
            ),
          );

          // Nothing was committed — main only receives merges and tags.
          expect(await dirtyFiles(), ['pubspec.lock']);
        });

        test('a clean tree on main does not throw — nothing to do', () async {
          await run('git', ['checkout', 'main']);

          final result = await systemCommit.commit(
            directory: d,
            ggLog: messages.add,
            message: '#gg: Update pubspec.lock',
          );

          expect(result.systemCommitCreated, isFalse);
        });
      });

      test('throws on unresolved merge conflicts', () async {
        // Build a real conflict on the feature branch.
        await addAndCommitSampleFile(d, fileName: 'c.txt', content: 'feature');
        await run('git', ['checkout', 'main']);
        await addAndCommitSampleFile(d, fileName: 'c.txt', content: 'main');
        await run('git', ['checkout', 'CDM-1']);
        final merge = await Process.run('git', [
          'merge',
          'main',
        ], workingDirectory: d.path);
        expect(merge.exitCode, isNot(0)); // conflict

        await expectLater(
          systemCommit.commit(
            directory: d,
            ggLog: messages.add,
            message: '#gg: Update pubspec.lock',
          ),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('unresolved merge conflicts'),
            ),
          ),
        );
      });

      group('ammendWhenNotPushed', () {
        test(
          'folds into an unpushed gg commit and keeps its message',
          () async {
            await pushLocalChangesUpstream(d, 'CDM-1');

            // An unpushed gg commit sits at HEAD.
            await File('${d.path}/pubspec.lock').writeAsString('one');
            await systemCommit.commit(
              directory: d,
              ggLog: messages.add,
              message: '#gg: First bookkeeping',
            );
            final countBefore = await commitCount(d);

            await File('${d.path}/CHANGELOG.md').writeAsString('# C');
            final result = await systemCommit.commit(
              directory: d,
              ggLog: messages.add,
              message: '#gg: Second bookkeeping',
              ammendWhenNotPushed: true,
            );

            expect(result.systemCommitCreated, isTrue);
            expect(await commitCount(d), countBefore);
            expect(await headSubject(), '#gg: First bookkeeping');
            expect(
              await filesOf('HEAD'),
              containsAll(<String>['pubspec.lock', 'CHANGELOG.md']),
            );
          },
        );

        test('never amends a user commit', () async {
          await pushLocalChangesUpstream(d, 'CDM-1');

          // HEAD is a user commit.
          await addAndCommitSampleFile(d, fileName: 'work.txt', content: 'w');
          final countBefore = await commitCount(d);

          await File('${d.path}/pubspec.lock').writeAsString('generated');
          await systemCommit.commit(
            directory: d,
            ggLog: messages.add,
            message: '#gg: Update pubspec.lock',
            ammendWhenNotPushed: true,
          );

          // A new commit was created — the user commit stayed untouched.
          expect(await commitCount(d), countBefore + 1);
          expect(await headSubject(), '#gg: Update pubspec.lock');
          expect(await subjectOf('HEAD~1'), isNot(startsWith('#gg')));
        });

        test('never amends when a user commit was just created', () async {
          await pushLocalChangesUpstream(d, 'CDM-1');

          // An unpushed gg commit sits at HEAD ...
          await File('${d.path}/pubspec.lock').writeAsString('one');
          await systemCommit.commit(
            directory: d,
            ggLog: messages.add,
            message: '#gg: First bookkeeping',
          );

          // ... but this run also finds foreign changes.
          await File('${d.path}/user_code.dart').writeAsString('user work');
          await File('${d.path}/CHANGELOG.md').writeAsString('# C');

          final result = await systemCommit.commit(
            directory: d,
            ggLog: messages.add,
            message: '#gg: Second bookkeeping',
            ammendWhenNotPushed: true,
            userCommitMessage: (_) => 'My work',
          );

          // Amending now would fold gg files into the just-created user
          // commit — instead a separate gg commit follows it.
          expect(result.userCommitCreated, isTrue);
          expect(await headSubject(), '#gg: Second bookkeeping');
          expect(await subjectOf('HEAD~1'), 'My work');
          expect(await subjectOf('HEAD~2'), '#gg: First bookkeeping');
        });
      });

      test('records the state when stateKey is given', () async {
        await File('${d.path}/pubspec.lock').writeAsString('generated');

        await systemCommit.commit(
          directory: d,
          ggLog: messages.add,
          message: '#gg: Update pubspec.lock',
          stateKey: GgState.doCommitKey,
        );

        final state = GgState(ggLog: messages.add);
        expect(
          await state.readSuccess(
            directory: d,
            key: GgState.doCommitKey,
            ggLog: messages.add,
          ),
          isTrue,
        );
      });

      group('when the commit rewrites a manifest', () {
        // The recorded »everything is committed« hash covers the content of
        // the tree, and a manifest is part of it — unlike a lock file, which
        // GgState.ignoreFiles skips. So a bookkeeping commit that rewrites
        // pubspec.yaml — changed references, tightened constraints —
        // invalidates the recorded answer, and every gate reading it through
        // »gg did commit« (can merge, can publish) reports a spurious »Not
        // committed yet« unless the state is recorded anew.
        setUp(() async {
          await addAndCommitSampleFile(
            d,
            fileName: 'pubspec.yaml',
            content: 'dependencies:\n  gg_git: ^4.0.0\n',
          );
          await GgState(
            ggLog: messages.add,
          ).writeSuccess(directory: d, key: GgState.doCommitKey);

          await File(
            '${d.path}/pubspec.yaml',
          ).writeAsString('dependencies:\n  gg_git: ^4.1.0\n');
        });

        test('the recorded state goes stale without a stateKey', () async {
          await systemCommit.commit(
            directory: d,
            ggLog: messages.add,
            message: '#gg: changed references to pub.dev',
          );

          expect(
            await GgState(ggLog: messages.add).readSuccess(
              directory: d,
              key: GgState.doCommitKey,
              ggLog: messages.add,
            ),
            isFalse,
          );
        });

        test('the stateKey keeps »gg did commit« answering yes', () async {
          await systemCommit.commit(
            directory: d,
            ggLog: messages.add,
            message: '#gg: changed references to pub.dev',
            stateKey: GgState.doCommitKey,
          );

          expect(
            await GgState(ggLog: messages.add).readSuccess(
              directory: d,
              key: GgState.doCommitKey,
              ggLog: messages.add,
            ),
            isTrue,
          );
        });
      });
    });
  });
}

// .............................................................................
/// The number of commits in [directory].
Future<int> commitCount(Directory directory) async {
  final result = await Process.run('git', [
    'rev-list',
    '--count',
    'HEAD',
  ], workingDirectory: directory.path);
  return int.parse(result.stdout.toString().trim());
}
