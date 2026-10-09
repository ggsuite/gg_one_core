// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_one_core/gg_one_core.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late ContributedCommits contributedCommits;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('contributed_commits_test_');
    contributedCommits = ContributedCommits();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  // ...........................................................................
  /// Runs git with [args] in [dir], throwing on failure.
  Future<void> git(Directory dir, List<String> args) async {
    final result = await Process.run(
      'git',
      args,
      workingDirectory: dir.path,
      runInShell: true,
    );
    if (result.exitCode != 0) {
      throw Exception('git ${args.join(' ')} failed: ${result.stderr}');
    }
  }

  // ...........................................................................
  /// Creates a repo holding one commit on [defaultBranch], with
  /// `origin/<defaultBranch>` pointing at it — the state a freshly cloned
  /// repository is in.
  Future<Directory> createRepo({String defaultBranch = 'main'}) async {
    final dir = Directory(path.join(tempDir.path, 'a'))..createSync();
    await git(dir, ['init', '--initial-branch', defaultBranch]);
    await git(dir, ['config', 'user.email', 'test@example.com']);
    await git(dir, ['config', 'user.name', 'Test']);
    File(path.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: a\n');
    await git(dir, ['add', '.']);
    await git(dir, ['commit', '-m', 'Initial commit']);
    await git(dir, [
      'update-ref',
      'refs/remotes/origin/$defaultBranch',
      defaultBranch,
    ]);
    return dir;
  }

  // ...........................................................................
  /// Commits [content] to [file] in [dir] using [message].
  Future<void> commit(
    Directory dir,
    String file,
    String content,
    String message,
  ) async {
    final target = File(path.join(dir.path, file));
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(content);
    await git(dir, ['add', '-A']);
    await git(dir, ['commit', '-m', message]);
  }

  group('ContributedCommits', () {
    group('manualCommitReason(directory)', () {
      group('returns null', () {
        test('when the feature branch carries gg commits only', () async {
          final dir = await createRepo();
          await git(dir, ['checkout', '-b', 'feat']);
          await commit(
            dir,
            'pubspec_overrides.yaml',
            'refs',
            '#gg: changed references to git',
          );

          expect(
            await contributedCommits.manualCommitReason(directory: dir),
            isNull,
          );
        });

        test('when a manual commit only writes a CHANGELOG entry', () async {
          // This is what `gg do commit` used to leave behind in a repo gg
          // itself had touched: an entry under the user's message, which made
          // a repository nobody edited look like work to release.
          final dir = await createRepo();
          await git(dir, ['checkout', '-b', 'feat']);
          await commit(dir, 'CHANGELOG.md', '# Changelog\n', 'My commit');

          expect(
            await contributedCommits.manualCommitReason(directory: dir),
            isNull,
          );
        });

        test('when a manual commit only writes derived files', () async {
          final dir = await createRepo();
          await git(dir, ['checkout', '-b', 'feat']);
          File(path.join(dir.path, 'pubspec.lock')).writeAsStringSync('lock');
          await commit(dir, '.gg/gg.json', '{}', 'My commit');

          expect(
            await contributedCommits.manualCommitReason(directory: dir),
            isNull,
          );
        });

        test('when the derived files sit in a package subfolder', () async {
          // A repository may keep its package below the root; git then
          // reports »packages/x/CHANGELOG.md«.
          final dir = await createRepo();
          await git(dir, ['checkout', '-b', 'feat']);
          final nested = Directory(path.join(dir.path, 'packages', 'x', '.gg'))
            ..createSync(recursive: true);
          File(path.join(nested.path, 'gg.json')).writeAsStringSync('{}');
          await commit(
            dir,
            path.join('packages', 'x', 'CHANGELOG.md'),
            '# Changelog\n',
            'My commit',
          );

          expect(
            await contributedCommits.manualCommitReason(directory: dir),
            isNull,
          );
        });

        test('when the branch contributes no commits at all', () async {
          final dir = await createRepo();

          expect(
            await contributedCommits.manualCommitReason(directory: dir),
            isNull,
          );
        });

        test('when the work sits before the merge-back commit', () async {
          // gg squash-merges into the default branch, so the original feature
          // commits never become its ancestors. The merge-back marks what is
          // already released.
          final dir = await createRepo();
          await git(dir, ['checkout', '-b', 'feat']);
          await commit(dir, 'lib.dart', 'void main() {}', 'Released work');
          await commit(
            dir,
            'merge-back.txt',
            'x',
            '#gg: merge the published main back into feat',
          );
          await commit(
            dir,
            'pubspec_overrides.yaml',
            'refs',
            '#gg: restored local workspace references',
          );

          expect(
            await contributedCommits.manualCommitReason(directory: dir),
            isNull,
          );
        });

        test('when a gg commit only changes dependency constraints', () async {
          // `gg do push` upgrades with --tighten; dev dependencies and
          // dependency_overrides never reach a consumer.
          final dir = await createRepo();
          await commit(
            dir,
            'pubspec.yaml',
            'name: a\ndependencies:\n  b: ^1.0.0\n',
            'Add b',
          );
          await git(dir, ['update-ref', 'refs/remotes/origin/main', 'HEAD']);
          await git(dir, ['checkout', '-b', 'feat']);
          await commit(
            dir,
            'pubspec.yaml',
            'name: a\n'
                'dependencies:\n'
                '  b: ^1.2.0\n'
                'dev_dependencies:\n'
                '  helix: ^1.0.0\n'
                'dependency_overrides:\n'
                '  b:\n'
                '    path: ../b\n',
            '#gg: dart pub upgrade --major-versions --tighten',
          );

          expect(
            await contributedCommits.manualCommitReason(directory: dir),
            isNull,
          );
        });

        test('when a gg commit rewrites the specs in package.json', () async {
          final dir = await createRepo();
          await commit(
            dir,
            'package.json',
            '{"dependencies": {"b": "^1.0.0"}}',
            'Add package.json',
          );
          await git(dir, ['update-ref', 'refs/remotes/origin/main', 'HEAD']);
          await git(dir, ['checkout', '-b', 'feat']);
          await commit(
            dir,
            'package.json',
            '{"dependencies": {"b": "link:../b"},'
                ' "devDependencies": {"c": "^1.0.0"}}',
            '#gg: changed references to path',
          );

          expect(
            await contributedCommits.manualCommitReason(directory: dir),
            isNull,
          );
        });

        test('when the remote declares the default branch', () async {
          final dir = await createRepo(defaultBranch: 'develop');
          await git(dir, [
            'symbolic-ref',
            'refs/remotes/origin/HEAD',
            'refs/remotes/origin/develop',
          ]);
          await git(dir, ['checkout', '-b', 'feat']);
          await commit(
            dir,
            'pubspec.yaml',
            'name: a\nversion: 1.0.1\n',
            '#gg: increase version',
          );

          expect(
            await contributedCommits.manualCommitReason(directory: dir),
            isNull,
          );
        });
      });

      group('returns a reason', () {
        test('naming the manual commit', () async {
          final dir = await createRepo();
          await git(dir, ['checkout', '-b', 'feat']);
          await commit(dir, 'lib.dart', 'void main() {}', 'Manual work');

          expect(
            await contributedCommits.manualCommitReason(directory: dir),
            contains('the repo contains the manual commit »Manual work«'),
          );
        });

        test('for a manual commit that changes nothing', () async {
          // An empty commit names no file, so nothing proves it derived —
          // undecidable counts as work.
          final dir = await createRepo();
          await git(dir, ['checkout', '-b', 'feat']);
          await git(dir, ['commit', '--allow-empty', '-m', 'Empty work']);

          expect(
            await contributedCommits.manualCommitReason(directory: dir),
            contains('»Empty work«'),
          );
        });

        test('naming the user file a gg commit swallowed', () async {
          final dir = await createRepo();
          await git(dir, ['checkout', '-b', 'feat']);
          await commit(dir, 'lib.dart', 'void main() {}', '#gg: dart pub get');

          expect(
            await contributedCommits.manualCommitReason(directory: dir),
            contains('also changes »lib.dart«'),
          );
        });

        group('for a gg commit that changes dependency names', () {
          // The scenario of the old `gg do add`: the user's new dependency
          // ended up in the bookkeeping commit and was lost on publish.
          test('naming the dependency added to a pubspec.yaml', () async {
            final dir = await createRepo();
            await git(dir, ['checkout', '-b', 'feat']);
            File(path.join(dir.path, 'pubspec_overrides.yaml'))
                .writeAsStringSync('dependency_overrides: {}\n');
            await commit(
              dir,
              'pubspec.yaml',
              'name: a\ndependencies:\n  c: ^1.0.0\n  b: ^1.0.0\n',
              '#gg: changed references to path',
            );

            expect(
              await contributedCommits.manualCommitReason(directory: dir),
              'the gg commit »#gg: changed references to path« changes the '
              'dependencies of »pubspec.yaml« (added: b, c)',
            );
          });

          test('naming added and removed package.json dependencies, '
              'nested at any depth', () async {
            final dir = await createRepo();
            final manifest = path.join('packages', 'x', 'package.json');
            await commit(
              dir,
              manifest,
              '{"peerDependencies": {"p": "^1.0.0"}}',
              'Add package',
            );
            await git(dir, ['update-ref', 'refs/remotes/origin/main', 'HEAD']);
            await git(dir, ['checkout', '-b', 'feat']);
            await commit(
              dir,
              manifest,
              '{"optionalDependencies": {"o": "^1.0.0"}}',
              '#gg: changed references to path',
            );

            expect(
              await contributedCommits.manualCommitReason(directory: dir),
              contains(
                'the dependencies of »packages/x/package.json« '
                '(added: o; removed: p)',
              ),
            );
          });

          test('when the gg commit adds the manifest itself', () async {
            final dir = await createRepo();
            await git(dir, ['checkout', '-b', 'feat']);
            await commit(
              dir,
              'package.json',
              '{"dependencies": {"b": "^1.0.0"}}',
              '#gg: changed references to path',
            );

            expect(
              await contributedCommits.manualCommitReason(directory: dir),
              contains('»package.json« (added: b)'),
            );
          });

          test('naming a dependency the gg commit removes', () async {
            final dir = await createRepo();
            await commit(
              dir,
              'pubspec.yaml',
              'name: a\ndependencies:\n  b: ^1.0.0\n',
              'Add b',
            );
            await git(dir, ['update-ref', 'refs/remotes/origin/main', 'HEAD']);
            await git(dir, ['checkout', '-b', 'feat']);
            await commit(
              dir,
              'pubspec.yaml',
              '# all gone\n',
              '#gg: changed references to path',
            );

            expect(
              await contributedCommits.manualCommitReason(directory: dir),
              contains('(removed: b)'),
            );
          });

          for (final (name, content) in [
            ('pubspec.yaml', 'name: a\ndependencies: [b]\n'),
            ('pubspec.yaml', '- not a map\n'),
            ('pubspec.yaml', 'name: a\nrepository:https://x\n'),
            ('package.json', '{"dependencies": '),
          ]) {
            test('when $name cannot be read: ${jsonEncode(content)}', () async {
              final dir = await createRepo();
              await git(dir, ['checkout', '-b', 'feat']);
              await commit(dir, name, content, '#gg: dart pub get');

              expect(
                await contributedCommits.manualCommitReason(directory: dir),
                contains('changes »$name«, whose dependencies cannot be read'),
              );
            });
          }
        });

        test('when there is no branch to compare against', () async {
          final dir = Directory(path.join(tempDir.path, 'a'))..createSync();
          await git(dir, ['init', '--initial-branch', 'trunk']);
          await git(dir, ['config', 'user.email', 'test@example.com']);
          await git(dir, ['config', 'user.name', 'Test']);
          File(path.join(dir.path, 'a.txt')).writeAsStringSync('a');
          await git(dir, ['add', '.']);
          await git(dir, ['commit', '-m', 'Initial commit']);

          expect(
            await contributedCommits.manualCommitReason(directory: dir),
            'no main branch to compare against was found',
          );
        });

        test('when git itself cannot be run', () async {
          final failing = ContributedCommits(
            processRunner: (
              executable,
              arguments, {
              workingDirectory,
              environment,
              runInShell = true,
            }) async => throw Exception('git is missing'),
          );

          expect(
            await failing.manualCommitReason(directory: tempDir),
            contains('the git history could not be inspected'),
          );
        });
      });
    });

    test('MockContributedCommits can be instantiated', () {
      expect(MockContributedCommits(), isA<ContributedCommits>());
    });
  });
}
