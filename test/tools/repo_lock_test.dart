// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gg_one_core/src/tools/repo_lock.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

// .............................................................................
/// A process of its own that holds a lock, see repo_lock_holder.dart.
class _Holder {
  _Holder._(this._process, this._lines);

  final Process _process;
  final StreamIterator<String> _lines;

  /// Starts the process with [args] and waits until it says [ready].
  static Future<_Holder> start(
    List<String> args, {
    required String ready,
  }) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      path.join('test', 'tools', 'repo_lock_holder.dart'),
      ...args,
    ]);
    // What goes wrong in the other process is said in this one.
    process.stderr.transform(utf8.decoder).listen(stderr.write);

    final holder = _Holder._(
      process,
      StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ),
    );
    expect(await holder._nextLine(), ready);
    return holder;
  }

  Future<String?> _nextLine() async =>
      await _lines.moveNext() ? _lines.current : null;

  /// Lets the process give its lock back and end.
  Future<void> release() async {
    _process.stdin.writeln('release');
    await _process.stdin.flush();
    expect(await _nextLine(), 'done');
    await _process.exitCode;
  }

  /// Ends the process on the spot: it gives nothing back.
  Future<void> die() async {
    _process.stdin.writeln('die');
    await _process.stdin.flush();
    await _process.exitCode;
  }
}

void main() {
  const lifetime = Duration(seconds: 30);

  late Directory repo;
  late File lockFile;
  late String name;
  final messages = <String>[];
  void ggLog(String message) => messages.add(rmControls(message));

  /// The time of the test. Only the test moves it.
  late DateTime now;

  /// A lock on the clock of the test that asks and renews often.
  RepoLock lockOf() => RepoLock(
    renewEvery: const Duration(milliseconds: 20),
    lifetime: lifetime,
    pollInterval: const Duration(milliseconds: 5),
    now: () => now,
  );

  /// Time for a few renewals and a few questions for the lock. Only for
  /// what must not happen: what has to happen is waited for with [until].
  Future<void> aMoment() =>
      Future<void>.delayed(const Duration(milliseconds: 100));

  /// Waits until [isTrue]. The timeout of the test ends a wait in vain.
  Future<void> until(bool Function() isTrue) async {
    while (!isTrue()) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// Waits until the lock expires at [expires].
  Future<void> untilExpiresAt(DateTime expires) =>
      until(() => RepoLock.leaseIn(lockFile)?.expires == expires);

  /// Makes the lock look held by a run that is not there, until [expires].
  void leaveLockOfAnotherRun({required DateTime expires}) =>
      lockFile.writeAsStringSync(
        RepoLock.textOf((owner: 'another-run', expires: expires)),
      );

  setUp(() {
    messages.clear();
    now = DateTime.utc(2026, 11, 14, 12);
    repo = Directory.systemTemp.createTempSync('repo_lock_test');
    Directory(path.join(repo.path, '.git')).createSync();
    lockFile = RepoLock.fileOf(repo)!;
    name = path.basename(repo.path);
  });

  tearDown(() => repo.deleteSync(recursive: true));

  group('RepoLock', () {
    group('fileOf', () {
      test('is a file in the .git folder of a repository', () {
        expect(
          lockFile.path,
          path.canonicalize(path.join(repo.path, '.git', 'gg-run-lock')),
        );
        expect(RepoLock.fileName, 'gg-run-lock');
      });

      test('is in the folder the .git file of a worktree names', () {
        final gitDir = Directory(path.join(repo.path, 'git_dirs', 'tree'))
          ..createSync(recursive: true);
        final expected = path.canonicalize(
          path.join(gitDir.path, RepoLock.fileName),
        );

        for (final named in [
          gitDir.path,
          path.join('..', 'git_dirs', 'tree'),
        ]) {
          final worktree = Directory(path.join(repo.path, 'worktree'))
            ..createSync();
          File(path.join(worktree.path, '.git'))
              .writeAsStringSync('# a worktree\ngitdir: $named\n');

          expect(RepoLock.fileOf(worktree)?.path, expected, reason: named);
          worktree.deleteSync(recursive: true);
        }
      });

      test('is null where the .git file names no folder', () {
        final worktree = Directory(path.join(repo.path, 'worktree'))
          ..createSync();
        final dotGit = File(path.join(worktree.path, '.git'));

        dotGit.writeAsStringSync('gitdir: ../missing\n');
        expect(RepoLock.fileOf(worktree), isNull);

        dotGit.writeAsStringSync('no folder here\n');
        expect(RepoLock.fileOf(worktree), isNull);
      });

      test('is null outside of a repository', () {
        final plain = Directory(path.join(repo.path, 'plain'))..createSync();
        expect(RepoLock.fileOf(plain), isNull);
      });
    });

    group('leaseIn', () {
      test('tells who holds the lock and until when', () {
        final expires = now.add(lifetime);
        leaveLockOfAnotherRun(expires: expires);

        expect(RepoLock.leaseIn(lockFile), (
          owner: 'another-run',
          expires: expires,
        ));
      });

      test('is null when nobody holds the lock', () {
        // No file.
        expect(RepoLock.leaseIn(lockFile), isNull);

        // An empty file, and files that are not what a lock writes.
        for (final text in ['', 'garbage', '[]', '{"owner": 1}', '{}']) {
          lockFile.writeAsStringSync(text);
          expect(RepoLock.leaseIn(lockFile), isNull, reason: text);
        }
      });
    });

    group('use', () {
      test('runs the body, holding the lock, and gives the lock '
          'back', () async {
        final result = await lockOf().use(
          directory: repo,
          ggLog: ggLog,
          body: (waited) async {
            expect(waited, isFalse);

            // The lock names this process and expires unless renewed.
            final lease = RepoLock.leaseIn(lockFile)!;
            expect(lease.owner, startsWith('$pid-'));
            expect(lease.expires, now.add(lifetime));
            return 'done';
          },
        );

        expect(result, 'done');
        expect(messages, isEmpty);
        expect(lockFile.readAsStringSync(), isEmpty);
      });

      test('makes a second run wait for the first', () async {
        final lock = lockOf();
        final firstIsDone = Completer<void>();
        final order = <String>[];

        final first = lock.use(
          directory: repo,
          ggLog: ggLog,
          body: (_) async {
            order.add('first');
            await firstIsDone.future;
            order.add('first done');
          },
        );
        final second = lock.use(
          directory: repo,
          ggLog: ggLog,
          body: (waited) async {
            order.add('second, waited: $waited');
          },
        );

        // The second run asks many times, and says once that it waits.
        await aMoment();
        expect(order, ['first']);
        expect(messages, ['Another gg run works in $name. Waiting for it …']);

        firstIsDone.complete();
        await Future.wait([first, second]);
        expect(order, ['first', 'first done', 'second, waited: true']);
        expect(messages, hasLength(1));
      });

      test('runs code that holds the lock already right away', () async {
        final lock = lockOf();

        final result = await lock.use(
          directory: repo,
          ggLog: ggLog,
          body: (_) => lock.use(
            directory: repo,
            ggLog: ggLog,
            body: (waited) async => 'inner, waited: $waited',
          ),
        );

        expect(result, 'inner, waited: false');
        expect(messages, isEmpty);
      });

      test('does not make runs in different repositories wait', () async {
        final other = Directory.systemTemp.createTempSync('repo_lock_other');
        addTearDown(() => other.deleteSync(recursive: true));
        Directory(path.join(other.path, '.git')).createSync();
        final lock = lockOf();

        final result = await lock.use(
          directory: repo,
          ggLog: ggLog,
          body: (_) => lock.use(
            directory: other,
            ggLog: ggLog,
            body: (waited) async => waited,
          ),
        );

        expect(result, isFalse);
        expect(messages, isEmpty);
      });

      test('gives the lock back when the body throws', () async {
        final lock = lockOf();

        await expectLater(
          lock.use<void>(
            directory: repo,
            ggLog: ggLog,
            body: (_) async => throw StateError('broken'),
          ),
          throwsStateError,
        );

        expect(RepoLock.leaseIn(lockFile), isNull);
        expect(
          await lock.use(
            directory: repo,
            ggLog: ggLog,
            body: (waited) async => waited,
          ),
          isFalse,
        );
      });

      test('runs the body outside of a repository', () async {
        final plain = Directory(path.join(repo.path, 'plain'))..createSync();

        final waited = await lockOf().use(
          directory: plain,
          ggLog: ggLog,
          body: (waited) async => waited,
        );

        expect(waited, isFalse);
      });

      test('works without the lock when the lock file cannot be '
          'used', () async {
        // A folder where the lock file belongs.
        Directory(lockFile.path).createSync();

        final waited = await lockOf().use(
          directory: repo,
          ggLog: ggLog,
          body: (waited) async => waited,
        );

        expect(waited, isFalse);
        expect(messages, isEmpty);
      });

      group('renews the lock', () {
        test('while the body runs', () async {
          await lockOf().use(
            directory: repo,
            ggLog: ggLog,
            body: (_) async {
              final taken = RepoLock.leaseIn(lockFile)!;

              // Ten seconds later the lock expires ten seconds later.
              now = now.add(const Duration(seconds: 10));
              await untilExpiresAt(now.add(lifetime));

              final renewed = RepoLock.leaseIn(lockFile)!;
              expect(renewed.owner, taken.owner);
              expect(renewed.expires, now.add(lifetime));
            },
          );
        });

        test('also when it expired, as long as no other run took '
            'it', () async {
          await lockOf().use(
            directory: repo,
            ggLog: ggLog,
            body: (_) async {
              now = now.add(lifetime * 2);
              await untilExpiresAt(now.add(lifetime));

              expect(RepoLock.leaseIn(lockFile)!.expires, now.add(lifetime));
            },
          );

          expect(messages, isEmpty);
        });

        test('and writes it again when the file was emptied', () async {
          await lockOf().use(
            directory: repo,
            ggLog: ggLog,
            body: (_) async {
              lockFile.writeAsStringSync('');
              await until(() => RepoLock.leaseIn(lockFile) != null);

              expect(RepoLock.leaseIn(lockFile)!.owner, startsWith('$pid-'));
            },
          );
        });

        test('but leaves it to the run that took it, with a '
            'warning', () async {
          final takenBy = now.add(const Duration(hours: 1));

          await lockOf().use(
            directory: repo,
            ggLog: ggLog,
            body: (_) async {
              // The renewals did not come, and another run took the lock.
              leaveLockOfAnotherRun(expires: takenBy);
              await until(() => messages.isNotEmpty);
              await aMoment();
            },
          );

          // Said once, however many renewals were due since.
          expect(messages, [
            'The lock of this gg run on $name was not renewed in time, and '
                'another gg run took it. Both may work in $name now.',
          ]);

          // The lock of the other run is neither renewed nor given back.
          expect(RepoLock.leaseIn(lockFile), (
            owner: 'another-run',
            expires: takenBy,
          ));
        });
      });

      group('with a lock another run left behind', () {
        test('waits while the lock is not expired, and takes it once it '
            'is', () async {
          leaveLockOfAnotherRun(expires: now.add(lifetime));
          var isRunning = false;

          final run = lockOf().use(
            directory: repo,
            ggLog: ggLog,
            body: (waited) async {
              isRunning = true;
              return waited;
            },
          );

          // One second before the lock expires.
          now = now.add(lifetime - const Duration(seconds: 1));
          await aMoment();
          expect(isRunning, isFalse);

          // Nobody renewed it.
          now = now.add(const Duration(seconds: 1));
          expect(await run, isTrue);
          expect(messages, [
            'Another gg run works in $name. Waiting for it …',
            'The other gg run did not renew its lock on $name for 30s. '
                'Going on without it.',
          ]);
        });

        test('takes a lock that expired before without a word', () async {
          leaveLockOfAnotherRun(expires: now.subtract(const Duration(days: 1)));

          final waited = await lockOf().use(
            directory: repo,
            ggLog: ggLog,
            body: (waited) async => waited,
          );

          expect(waited, isFalse);
          expect(messages, isEmpty);
        });

        test('takes a lock file that says nothing', () async {
          lockFile.writeAsStringSync('garbage');

          final waited = await lockOf().use(
            directory: repo,
            ggLog: ggLog,
            body: (waited) async => waited,
          );

          expect(waited, isFalse);
        });

        test('ends the wait when its process scope is cancelled', () async {
          leaveLockOfAnotherRun(expires: now.add(lifetime));
          final scope = GgProcessScope();

          final run = scope.run(
            () => lockOf().use<void>(
              directory: repo,
              ggLog: ggLog,
              body: (_) async => fail('must not run'),
            ),
          );
          final ended = expectLater(run, throwsA(isA<GgProcessCancelled>()));

          await aMoment();
          scope.cancel();
          await ended;

          // The lock of the other run is untouched.
          expect(RepoLock.leaseIn(lockFile)!.owner, 'another-run');
        });
      });

      group('with another process', () {
        /// The lock as gg uses it, with times short enough for a test.
        RepoLock realLock({required Duration lifetime}) => RepoLock(
          renewEvery: const Duration(milliseconds: 100),
          lifetime: lifetime,
          pollInterval: const Duration(milliseconds: 10),
        );

        test('waits for the run of the other process', () async {
          final other = await _Holder.start([
            'use',
            repo.path,
            '100',
            '30000',
          ], ready: 'holding');
          var isRunning = false;

          final run = realLock(lifetime: lifetime).use(
            directory: repo,
            ggLog: ggLog,
            body: (waited) async {
              isRunning = true;
              return waited;
            },
          );

          await aMoment();
          expect(isRunning, isFalse);

          await other.release();
          expect(await run, isTrue);
          expect(messages, ['Another gg run works in $name. Waiting for it …']);
        });

        test('waits as long as the other process renews its lock, and '
            'goes on once it died', () async {
          const lifetime = Duration(seconds: 2);
          final other = await _Holder.start([
            'use',
            repo.path,
            '100',
            '${lifetime.inMilliseconds}',
          ], ready: 'holding');
          var isRunning = false;

          final run = realLock(lifetime: lifetime).use(
            directory: repo,
            ggLog: ggLog,
            body: (waited) async {
              isRunning = true;
              return waited;
            },
          );

          // Longer than the lock lives: only renewals keep it.
          await Future<void>.delayed(lifetime * 1.5);
          expect(isRunning, isFalse);

          // The other run ends without giving the lock back.
          await other.die();
          expect(await run, isTrue);
          expect(messages, [
            'Another gg run works in $name. Waiting for it …',
            'The other gg run did not renew its lock on $name for 2s. '
                'Going on without it.',
          ]);
        });

        test('waits for the moment the other process is at the lock '
            'file', () async {
          final other = await _Holder.start([
            'file',
            lockFile.path,
          ], ready: 'locked');
          var isRunning = false;

          final run = realLock(lifetime: lifetime).use(
            directory: repo,
            ggLog: ggLog,
            body: (waited) async {
              isRunning = true;
              return waited;
            },
          );

          await aMoment();
          expect(isRunning, isFalse);

          // No run holds the lock: nothing to say, nothing waited for.
          await other.release();
          expect(await run, isFalse);
          expect(messages, isEmpty);
        });

        test('renews and gives back later when the other process is at '
            'the lock file', () async {
          final lock = realLock(lifetime: lifetime);
          final started = Completer<_Holder>();

          final run = lock.use(
            directory: repo,
            ggLog: ggLog,
            body: (_) async {
              started.complete(
                await _Holder.start(['file', lockFile.path], ready: 'locked'),
              );

              // Renewals are due, and skipped.
              await Future<void>.delayed(const Duration(milliseconds: 250));
            },
          );

          // The body ends, and the lock cannot be given back yet either.
          final other = await started.future;
          await Future<void>.delayed(const Duration(milliseconds: 350));
          await other.release();
          await run;

          expect(messages, isEmpty);
          expect(lockFile.readAsStringSync(), isEmpty);
        });
      });
    });
  });
}
