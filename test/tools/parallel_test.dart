// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_process/gg_process.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

// .............................................................................
/// A machine with [processors] processors and the [environment] given. It
/// is no Windows: a process is killed directly, not through taskkill.
class _Platform extends GgPlatformDelegate {
  _Platform({this.processors = 8, this.environment = const {}});

  final int processors;

  @override
  final Map<String, String> environment;

  @override
  int get numberOfProcessors => processors;

  @override
  String get operatingSystem => 'linux';
}

// .............................................................................
/// Starts fake processes that count how often they were killed.
class _FakeProcesses extends GgProcessDelegate {
  final List<_KillCounting> started = [];

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    final process = _KillCounting();
    started.add(process);
    return process;
  }

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) async => ProcessResult(0, 0, '', '');
}

class _KillCounting extends GgFakeProcess {
  int kills = 0;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    return super.kill(signal);
  }
}

// .............................................................................
/// Tasks the test finishes by hand, in the order it likes.
class _Tasks {
  _Tasks(int count)
    : _gates = List.generate(count, (_) => Completer<String>()),
      logs = List.filled(count, null),
      scopes = List.filled(count, null);

  final List<Completer<String>> _gates;

  /// The log each started task was given.
  final List<void Function(String)?> logs;

  /// The process scope each started task ran in.
  final List<GgProcessScope?> scopes;

  /// The indexes of the tasks in the order they were started.
  final List<int> started = [];

  Future<String> task(int index, void Function(String) ggLog) {
    started.add(index);
    logs[index] = ggLog;
    scopes[index] = GgProcessScope.current;
    return _gates[index].future;
  }

  void finish(int index) => _gates[index].complete('result $index');

  void fail(int index) => _gates[index].completeError(
    Exception('task $index failed'),
    StackTrace.fromString('stack of task $index'),
  );
}

/// Lets the futures completed so far run their callbacks.
Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  final messages = <String>[];

  setUp(messages.clear);
  tearDown(() {
    GgPlatformDelegate.current = null;
    GgProcessDelegate.current = null;
  });

  group('TaskSlots', () {
    /// Bodies the test finishes by hand; [running] counts the started ones
    /// that are not finished yet.
    ({
      Future<int> Function(int) body,
      List<Completer<void>> gates,
      List<int> started,
    })
    bodies(int count) {
      final gates = List.generate(count, (_) => Completer<void>());
      final started = <int>[];
      Future<int> body(int index) async {
        started.add(index);
        await gates[index].future;
        return index * 10;
      }

      return (body: body, gates: gates, started: started);
    }

    test('runs as many bodies at the same time as it has slots', () async {
      final slots = TaskSlots(2);
      final (:body, :gates, :started) = bodies(3);

      final results = [for (var i = 0; i < 3; i++) slots.use(() => body(i))];
      await _pump();
      expect(started, [0, 1]);

      // A finished body hands its slot to the one waiting.
      gates[1].complete();
      await _pump();
      expect(started, [0, 1, 2]);

      gates[0].complete();
      gates[2].complete();
      expect(await Future.wait(results), [0, 10, 20]);
    });

    test('gives the waiting bodies their slot in the order they '
        'asked', () async {
      final slots = TaskSlots(1);
      final (:body, :gates, :started) = bodies(3);

      final results = [for (var i = 0; i < 3; i++) slots.use(() => body(i))];
      for (var i = 0; i < 3; i++) {
        await _pump();
        expect(started, [for (var j = 0; j <= i; j++) j]);
        gates[i].complete();
      }

      await Future.wait(results);
    });

    test('frees the slot of a body that threw', () async {
      final slots = TaskSlots(1);

      await expectLater(
        slots.use<void>(() async => throw StateError('broken')),
        throwsStateError,
      );
      expect(await slots.use(() async => 'next'), 'next');
    });

    test('has at least one slot', () async {
      for (final count in [0, -5]) {
        expect(await TaskSlots(count).use(() async => 'ran'), 'ran');
      }
    });

    test('frees a slot again when nobody waits', () async {
      final slots = TaskSlots(1);

      expect(await slots.use(() async => 1), 1);
      expect(await slots.use(() async => 2), 2);
    });
  });

  group('waitForGitIndex', () {
    late Directory repo;
    late File lock;

    setUp(() {
      repo = Directory.systemTemp.createTempSync('wait_for_git_index');
      lock = File(path.join(repo.path, '.git', 'index.lock'));
      Directory(path.join(repo.path, '.git')).createSync();
    });

    tearDown(() => repo.deleteSync(recursive: true));

    test('returns at once without a directory', () async {
      await waitForGitIndex(null);
    });

    test('returns at once when git does not write the index', () async {
      final stopwatch = Stopwatch()..start();
      await waitForGitIndex(repo.path);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('waits until the lock of the index is gone', () async {
      lock.createSync();
      var isDone = false;
      final waiting = waitForGitIndex(
        repo.path,
        interval: const Duration(milliseconds: 5),
      ).whenComplete(() => isDone = true);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(isDone, isFalse);

      lock.deleteSync();
      await waiting;
      expect(isDone, isTrue);
    });

    test('gives up after the timeout', () async {
      lock.createSync();

      await waitForGitIndex(
        repo.path,
        timeout: const Duration(milliseconds: 30),
        interval: const Duration(milliseconds: 5),
      );

      expect(lock.existsSync(), isTrue);
    });
  });

  group('GgParallelism', () {
    /// A machine with [processors] and, when given, `GG_PARALLEL=[parallel]`.
    void machine(int processors, {String? parallel}) {
      GgPlatformDelegate.current = _Platform(
        processors: processors,
        environment: {GgParallelism.environmentVariable: ?parallel},
      );
    }

    group('heavy', () {
      test('is a quarter of the processors, at least one and at most '
          'four', () {
        int heavyOn(int processors) {
          machine(processors);
          return GgParallelism.heavy;
        }

        final heavy = {
          for (final processors in [0, 1, 2, 4, 7, 8, 11, 12, 15, 16, 22, 64])
            processors: heavyOn(processors),
        };

        expect(heavy, {
          // Small machines, e.g. CI runners: one heavy task at a time.
          0: 1,
          1: 1,
          2: 1,
          4: 1,
          7: 1,
          8: 2,
          11: 2,
          12: 3,
          15: 3,
          16: 4,
          // Never more than was measured, however large the machine.
          22: 4,
          64: 4,
        });
        expect(GgParallelism.maxHeavy, 4);
      });

      test('is what GG_PARALLEL says, also beyond the default', () {
        machine(22, parallel: '1');
        expect(GgParallelism.heavy, 1);

        machine(4, parallel: '10');
        expect(GgParallelism.heavy, 10);
      });
    });

    test('gives light tasks the processors of the machine, between 2 and '
        '16', () {
      machine(1);
      expect(GgParallelism.light, 2);

      machine(8);
      expect(GgParallelism.light, 8);

      machine(64);
      expect(GgParallelism.light, 16);
    });

    test('gives work at a remote small limits that do not grow with the '
        'machine', () {
      for (final processors in [1, 8, 22, 256]) {
        machine(processors);
        final reason = '$processors processors';
        expect(GgParallelism.network, 8, reason: reason);
        expect(GgParallelism.pushes, 4, reason: reason);
        expect(GgParallelism.pullRequests, 10, reason: reason);
        expect(GgParallelism.publishes, 4, reason: reason);
      }
    });

    /// What [ask] answers the bodies that hold one of the heavy slots while
    /// [runs] bodies hold a slot or wait for one.
    Future<List<int?>> askedBy(int runs, int? Function() ask) async {
      final slots = TaskSlots.heavy();
      final underWay = Completer<void>();
      final answered = Completer<void>();
      final answers = <int?>[];
      final bodies = [
        for (var i = 0; i < runs; i++)
          slots.use(() async {
            await underWay.future;
            // A body that gets its slot later is not asked.
            if (!answered.isCompleted) {
              answers.add(ask());
            }
            await answered.future;
          }),
      ];

      underWay.complete();
      await _pump();
      answered.complete();
      await Future.wait(bodies);
      return answers;
    }

    group('testFilesPerRun', () {
      Future<List<int?>> filesPerRun(int runs) =>
          askedBy(runs, () => GgParallelism.testFilesPerRun);

      test('leaves a test run outside of heavy slots to the test '
          'runner', () async {
        // However many runs the machine would take: this one is alone.
        machine(22);
        expect(GgParallelism.heavy, 4);
        expect(GgParallelism.testFilesPerRun, isNull);

        // Slots for something else say nothing about the machine.
        expect(
          await TaskSlots(4).use(() async => GgParallelism.testFilesPerRun),
          isNull,
        );
      });

      test('leaves the only test run under way to the test runner', () async {
        machine(22);
        expect(await filesPerRun(1), [null]);
      });

      test('shares what one test run would take between the runs under '
          'way, rounded up', () async {
        // A test runner takes half of the processors: 11 of 22.
        machine(22);
        expect(await filesPerRun(2), [6, 6]);
        expect(await filesPerRun(3), [4, 4, 4]);
        expect(await filesPerRun(4), [3, 3, 3, 3]);

        // 64 processors: four runs, eight of the 32 test files each.
        machine(64);
        expect(await filesPerRun(4), [8, 8, 8, 8]);
      });

      test('counts the runs that wait for a slot, but never more runs '
          'than slots', () async {
        machine(22);
        expect(await filesPerRun(9), [3, 3, 3, 3]);

        // 8 processors: two runs at a time, two test files each.
        machine(8);
        expect(await filesPerRun(5), [2, 2]);
      });

      test('shares between as many runs as GG_PARALLEL allows', () async {
        machine(22, parallel: '2');
        expect(await filesPerRun(4), [6, 6]);

        machine(22, parallel: '11');
        expect(await filesPerRun(11), List.filled(11, 1));

        machine(22, parallel: '1');
        expect(await filesPerRun(3), [null]);
      });

      test('gives every run at least one test file', () async {
        machine(22, parallel: '100');
        expect(await filesPerRun(100), List.filled(100, 1));

        for (final processors in [0, 1]) {
          machine(processors, parallel: '4');
          expect(await filesPerRun(4), [1, 1, 1, 1]);
        }
      });

      test('gives a run more of the machine once the others are '
          'done', () async {
        machine(22);
        final slots = TaskSlots.heavy();
        final gates = List.generate(2, (_) => Completer<void>());
        final asked = <int?>[];

        Future<void> run(int index) => slots.use(() async {
          await gates[index].future;
          asked.add(GgParallelism.testFilesPerRun);
        });

        // Two runs under way: the first to start its tests gets half.
        final first = run(0);
        final second = run(1);
        gates[0].complete();
        await first;
        expect(asked, [6]);

        // The other one is alone by now.
        gates[1].complete();
        await second;
        expect(asked, [6, null]);
      });

      test('answers for the heavy slots also inside of other slots', () async {
        machine(22);
        final heavy = TaskSlots.heavy();
        final lock = TaskSlots(1);
        final gate = Completer<void>();

        final other = heavy.use(() => gate.future);
        final files = await heavy.use(
          () => lock.use(() async => GgParallelism.testFilesPerRun),
        );
        expect(files, 6);

        gate.complete();
        await other;
      });
    });

    group('testTimeoutFactor', () {
      Future<List<int?>> factors(int runs) =>
          askedBy(runs, () => GgParallelism.testTimeoutFactor);

      test('leaves the timeouts of a test run outside of heavy slots '
          'alone', () async {
        machine(22);
        expect(GgParallelism.testTimeoutFactor, isNull);
        expect(
          await TaskSlots(4).use(() async => GgParallelism.testTimeoutFactor),
          isNull,
        );
      });

      test('gives a test as many times its usual time as test runs may '
          'share the machine', () async {
        machine(8);
        expect(await factors(2), [2, 2]);

        machine(22);
        expect(await factors(4), [4, 4, 4, 4]);

        // Also the only run under way: others may join it any time.
        expect(await factors(1), [4]);

        machine(22, parallel: '3');
        expect(await factors(1), [3]);
      });

      test('leaves the timeouts alone where one run goes at a time', () async {
        machine(4);
        expect(await factors(2), [null]);

        machine(22, parallel: '1');
        expect(await factors(2), [null]);
      });
    });

    test('runs everything one after the other with GG_PARALLEL=1', () {
      machine(64, parallel: '1');
      expect(GgParallelism.heavy, 1);
      expect(GgParallelism.light, 1);
      expect(GgParallelism.network, 1);
      expect(GgParallelism.pushes, 1);
      expect(GgParallelism.pullRequests, 1);
      expect(GgParallelism.publishes, 1);
    });

    test('lets GG_PARALLEL lower the other limits but never raise them', () {
      machine(16, parallel: '3');
      expect(GgParallelism.heavy, 3);
      expect(GgParallelism.light, 3);
      expect(GgParallelism.network, 3);
      expect(GgParallelism.pushes, 3);
      expect(GgParallelism.pullRequests, 3);
      expect(GgParallelism.publishes, 3);

      // A hundred heavy tasks, if somebody says so — but a remote is asked
      // no more often than without the variable.
      machine(4, parallel: '100');
      expect(GgParallelism.heavy, 100);
      expect(GgParallelism.light, 4);
      expect(GgParallelism.network, 8);
      expect(GgParallelism.pushes, 4);
      expect(GgParallelism.pullRequests, 10);
      expect(GgParallelism.publishes, 4);
    });

    test('ignores a GG_PARALLEL that is no positive number', () {
      for (final value in ['', 'many', '0', '-3']) {
        machine(32, parallel: value);
        expect(GgParallelism.heavy, 4, reason: 'GG_PARALLEL=$value');
        expect(GgParallelism.light, 16, reason: 'GG_PARALLEL=$value');
      }
    });
  });

  group('runInParallel', () {
    test('returns nothing when there are no tasks', () async {
      final results = await runInParallel<String>(
        count: 0,
        task: (index, ggLog) async => fail('must not be called'),
        ggLog: messages.add,
        maxParallel: 4,
      );
      expect(results, isEmpty);
    });

    test('returns the results in the order of the tasks', () async {
      final tasks = _Tasks(3);
      final run = runInParallel<String>(
        count: 3,
        task: tasks.task,
        ggLog: messages.add,
        maxParallel: 3,
      );

      tasks.finish(2);
      tasks.finish(0);
      tasks.finish(1);

      expect(await run, ['result 0', 'result 1', 'result 2']);
    });

    test('runs at most maxParallel tasks at the same time', () async {
      final tasks = _Tasks(4);
      final run = runInParallel<String>(
        count: 4,
        task: tasks.task,
        ggLog: messages.add,
        maxParallel: 2,
      );
      expect(tasks.started, [0, 1]);

      tasks.finish(1);
      await _pump();
      expect(tasks.started, [0, 1, 2]);

      tasks.finish(0);
      await _pump();
      expect(tasks.started, [0, 1, 2, 3]);

      tasks.finish(2);
      tasks.finish(3);
      await run;
    });

    test('runs one task after the other with maxParallel below 2', () async {
      for (final maxParallel in [1, 0, -1]) {
        final tasks = _Tasks(2);
        final run = runInParallel<String>(
          count: 2,
          task: tasks.task,
          ggLog: messages.add,
          maxParallel: maxParallel,
        );
        expect(tasks.started, [0]);

        tasks.finish(0);
        await _pump();
        expect(tasks.started, [0, 1]);

        tasks.finish(1);
        await run;
      }
    });

    test('logs as if the tasks had run one after the other', () async {
      final tasks = _Tasks(3);
      final run = runInParallel<String>(
        count: 3,
        task: tasks.task,
        ggLog: messages.add,
        maxParallel: 3,
      );

      // The first task is live, the others are held back.
      tasks.logs[2]!('2a');
      tasks.logs[0]!('0a');
      tasks.logs[1]!('1a');
      expect(messages, ['0a']);

      // A later task finishing changes nothing.
      tasks.logs[2]!('2b');
      tasks.finish(2);
      await _pump();
      expect(messages, ['0a']);

      // The first task is done: the second one is live now, and what it
      // held back is logged.
      tasks.logs[0]!('0b');
      tasks.finish(0);
      await _pump();
      expect(messages, ['0a', '0b', '1a']);
      tasks.logs[1]!('1b');
      expect(messages, ['0a', '0b', '1a', '1b']);

      // The second one done as well: the third one finished long ago.
      tasks.finish(1);
      await run;
      expect(messages, ['0a', '0b', '1a', '1b', '2a', '2b']);
    });

    test('runs every task in a process scope of its own', () async {
      final tasks = _Tasks(2);
      final run = runInParallel<String>(
        count: 2,
        task: tasks.task,
        ggLog: messages.add,
        maxParallel: 2,
      );

      expect(tasks.scopes[0], isNotNull);
      expect(tasks.scopes[1], isNotNull);
      expect(tasks.scopes[0], isNot(same(tasks.scopes[1])));

      tasks.finish(0);
      tasks.finish(1);
      await run;
    });

    test('reports a task that throws right away', () async {
      await expectLater(
        runInParallel<String>(
          count: 1,
          task: (index, ggLog) => throw StateError('broken'),
          ggLog: messages.add,
          maxParallel: 1,
        ),
        throwsStateError,
      );
    });

    group('when a task fails', () {
      test('throws its error with its stack trace', () async {
        final tasks = _Tasks(1);
        final run = runInParallel<String>(
          count: 1,
          task: tasks.task,
          ggLog: messages.add,
          maxParallel: 1,
        );
        tasks.fail(0);

        Object? error;
        StackTrace? stackTrace;
        try {
          await run;
        } catch (e, s) {
          error = e;
          stackTrace = s;
        }

        expect('$error', 'Exception: task 0 failed');
        expect('$stackTrace', contains('stack of task 0'));
      });

      test('starts no further task', () async {
        final tasks = _Tasks(4);
        final run = runInParallel<String>(
          count: 4,
          task: tasks.task,
          ggLog: messages.add,
          maxParallel: 2,
        );
        tasks.fail(0);
        tasks.finish(1);

        await expectLater(run, throwsException);
        expect(tasks.started, [0, 1]);
      });

      test('throws the error of the first failed task in order', () async {
        final tasks = _Tasks(3);
        final run = runInParallel<String>(
          count: 3,
          task: tasks.task,
          ggLog: messages.add,
          maxParallel: 3,
        );
        tasks.fail(2);
        await _pump();
        tasks.fail(1);
        await _pump();
        tasks.finish(0);

        await expectLater(
          run,
          throwsA(
            isA<Exception>().having(
              (e) => '$e',
              'message',
              'Exception: task 1 failed',
            ),
          ),
        );
      });

      group('without cancelOnError', () {
        test('lets the running tasks finish and logs them', () async {
          final tasks = _Tasks(3);
          var isDone = false;
          final run = runInParallel<String>(
            count: 3,
            task: tasks.task,
            ggLog: messages.add,
            maxParallel: 3,
          ).whenComplete(() => isDone = true);
          run.ignore();

          tasks.logs[0]!('0 ok');
          tasks.finish(0);
          tasks.logs[1]!('1 failed');
          tasks.fail(1);
          await _pump();

          // The third task still runs: nothing is thrown yet.
          expect(isDone, isFalse);
          expect(tasks.scopes[2]!.isCancelled, isFalse);

          tasks.logs[2]!('2 ok');
          tasks.finish(2);

          await expectLater(run, throwsException);
          expect(messages, ['0 ok', '1 failed', '2 ok']);
        });
      });

      group('with cancelOnError', () {
        test('cancels the tasks after the failed one', () async {
          final tasks = _Tasks(4);
          final run = runInParallel<String>(
            count: 4,
            task: tasks.task,
            ggLog: messages.add,
            maxParallel: 3,
            cancelOnError: true,
          );
          run.ignore();

          tasks.fail(1);
          await _pump();

          expect(tasks.scopes[0]!.isCancelled, isFalse);
          expect(tasks.scopes[1]!.isCancelled, isFalse);
          expect(tasks.scopes[2]!.isCancelled, isTrue);

          tasks.finish(0);
          await expectLater(run, throwsException);
          expect(tasks.started, [0, 1, 2]);
        });

        test('does not wait for the cancelled tasks', () async {
          final tasks = _Tasks(2);
          final run = runInParallel<String>(
            count: 2,
            task: tasks.task,
            ggLog: messages.add,
            maxParallel: 2,
            cancelOnError: true,
          );
          tasks.fail(0);

          // The second task never finishes.
          await expectLater(run, throwsException);
        });

        test('waits for the tasks before the failed one', () async {
          final tasks = _Tasks(2);
          var isDone = false;
          final run = runInParallel<String>(
            count: 2,
            task: tasks.task,
            ggLog: messages.add,
            maxParallel: 2,
            cancelOnError: true,
          ).whenComplete(() => isDone = true);
          run.ignore();

          tasks.fail(1);
          await _pump();
          expect(isDone, isFalse);

          tasks.finish(0);
          await expectLater(run, throwsException);
        });

        test('logs nothing of the cancelled tasks', () async {
          final tasks = _Tasks(3);
          final run = runInParallel<String>(
            count: 3,
            task: tasks.task,
            ggLog: messages.add,
            maxParallel: 3,
            cancelOnError: true,
          );
          run.ignore();

          tasks.logs[0]!('0 ok');
          tasks.logs[1]!('1 failed');
          tasks.logs[2]!('2 before');
          tasks.fail(1);
          await _pump();
          tasks.logs[2]!('2 after');
          tasks.finish(0);

          await expectLater(run, throwsException);
          expect(messages, ['0 ok', '1 failed']);

          // A cancelled task unwinding later is not heard either.
          tasks.fail(2);
          await _pump();
          expect(messages, ['0 ok', '1 failed']);
        });

        test('does not kill a process while git writes the index of its '
            'directory', () async {
          GgPlatformDelegate.current = _Platform();
          final processes = _FakeProcesses();
          GgProcessDelegate.current = processes;

          final repo = Directory.systemTemp.createTempSync('parallel_kill');
          addTearDown(() => repo.deleteSync(recursive: true));
          final lock = File(path.join(repo.path, '.git', 'index.lock'))
            ..createSync(recursive: true);

          final failFirst = Completer<void>();
          final run = runInParallel<void>(
            count: 2,
            maxParallel: 2,
            cancelOnError: true,
            ggLog: messages.add,
            task: (index, ggLog) async {
              if (index == 0) {
                await failFirst.future;
                throw StateError('first task failed');
              }
              // A test run in a repository git is committing in right now.
              final process = await ggStartProcess('dart', [
                'test',
              ], workingDirectory: repo.path);
              await process.exitCode;
            },
          );
          run.ignore();
          await _pump();
          expect(processes.started, hasLength(1));

          failFirst.complete();
          await expectLater(run, throwsStateError);
          await Future<void>.delayed(const Duration(milliseconds: 150));
          expect(processes.started.single.kills, 0);

          // git is through: now the test run is ended.
          lock.deleteSync();
          await Future<void>.delayed(const Duration(milliseconds: 200));
          expect(processes.started.single.kills, 1);
        });

        test('cancels again when an earlier task fails later', () async {
          final tasks = _Tasks(3);
          final run = runInParallel<String>(
            count: 3,
            task: tasks.task,
            ggLog: messages.add,
            maxParallel: 3,
            cancelOnError: true,
          );
          run.ignore();

          tasks.logs[1]!('1 held back');
          tasks.fail(2);
          await _pump();
          expect(tasks.scopes[1]!.isCancelled, isFalse);

          tasks.logs[0]!('0 failed');
          tasks.fail(0);
          await _pump();
          expect(tasks.scopes[1]!.isCancelled, isTrue);

          await expectLater(
            run,
            throwsA(
              isA<Exception>().having(
                (e) => '$e',
                'message',
                'Exception: task 0 failed',
              ),
            ),
          );
          expect(messages, ['0 failed']);
        });
      });
    });
  });
}
