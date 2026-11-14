// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:gg_log/gg_log.dart';
import 'package:gg_process/gg_process.dart';
import 'package:path/path.dart' as path;

/// How many tasks run at the same time.
///
/// Every kind of work has a limit of its own, because something else runs
/// out each time: processors and memory ([heavy]), the patience of the
/// operating system with many processes ([light]), and the patience of a
/// remote — a git host, a package registry — with one client ([network],
/// [pushes], [pullRequests], [publishes]).
///
/// The limits for local work follow the processors of the machine. The
/// limits for remote work are small fixed numbers that do **not** grow with
/// the machine: a remote throttles by client, whatever the client runs on,
/// so a workspace of a hundred repos must not open a hundred connections.
///
/// The environment variable [environmentVariable] holds a number of tasks:
/// it is the limit of the [heavy] tasks and caps all others, so
/// `GG_PARALLEL=1` runs everything one after the other and `GG_PARALLEL=2`
/// lets two test runs go at the same time. It never raises a limit for
/// remote work.
abstract final class GgParallelism {
  /// The environment variable that sets [heavy] and caps the other limits.
  static const String environmentVariable = 'GG_PARALLEL';

  /// The most [heavy] tasks a machine gets without [environmentVariable].
  static const int maxHeavy = 4;

  /// For tasks that keep several processors busy on their own: a test run,
  /// an analyzer, a compiler.
  ///
  /// A quarter of the processors, at least one and at most [maxHeavy],
  /// unless [environmentVariable] says otherwise. A test run takes half of
  /// the processors for its test files; side by side the runs share that
  /// half ([testFilesPerRun]), and with a quarter of the processors as the
  /// number of runs each one keeps at least two test files of its own. So a
  /// machine with fewer than eight processors — a usual CI runner — runs one
  /// heavy task at a time, as it always did.
  ///
  /// The cap is what was measured, and memory: every run brings an analyzer
  /// and a test runner of about a gigabyte each. Four runs with three test
  /// files each, on 22 processors, checked eleven repos 1.9 times as fast
  /// as one run at a time, three times without a failure.
  static int get heavy =>
      _fromEnvironment ?? (_processors ~/ 4).clamp(1, maxHeavy);

  /// How many test files the test run of the calling code loads and runs at
  /// the same time. Null when it has the machine for itself: the test
  /// runner then decides.
  ///
  /// A test runner takes half of the processors for its test files, as if
  /// the machine were its own. Several runs side by side would start a
  /// multiple of that, and tests that start processes then need so long
  /// that they run into their timeout. So a run that holds one of the
  /// [TaskSlots.heavy] gets its share, rounded up: together the runs start
  /// about as many test files as one run alone.
  ///
  /// The share follows the runs that are under way — the bodies that hold a
  /// slot or wait for one —, not the limit: the only repo to be tested gets
  /// the whole machine, however many runs the machine would take. A suite
  /// of 39 test files took 111 s with three of them at a time and 90 s with
  /// the eleven the test runner takes on 22 processors.
  static int? get testFilesPerRun {
    final runs = _heavySlots?._demand ?? 1;
    if (runs <= 1) {
      return null;
    }
    final files = max(1, _processors ~/ 2);
    return (files + runs - 1) ~/ runs;
  }

  /// How many times its usual time a test of the calling code may take.
  /// Null when its test run has the machine for itself: the timeouts then
  /// stay as the test runner sets them.
  ///
  /// The number of [TaskSlots.heavy] the run holds one of — the runs that
  /// may join it, also when it is the only one right now. A timeout ends a
  /// test that hangs, and it is set for a machine the test run has for
  /// itself; sharing the machine with three other runs made single suites up
  /// to three times as slow, and a test that needs ten seconds alone ran
  /// into its 30. A test that really hangs is still ended — after two
  /// minutes instead of half a minute.
  static int? get testTimeoutFactor {
    final runs = _heavySlots?._count ?? 1;
    return runs <= 1 ? null : runs;
  }

  /// The [TaskSlots.heavy] the calling code holds one of; null outside.
  static TaskSlots? get _heavySlots =>
      Zone.current[TaskSlots._heavyKey] as TaskSlots?;

  /// For tasks that wait for short processes, e.g. a few git calls.
  static int get light => _capped(_processors.clamp(2, 16));

  /// For tasks that read from a remote: `git fetch`, `git ls-remote`, a
  /// lookup at a registry.
  ///
  /// Eight, whatever the machine. A git host limits how many connections
  /// one client may open at once and how fast it may open them, and answers
  /// the surplus with dropped connections.
  static int get network => _capped(8);

  /// For tasks that write to a git remote: `git push`, deleting a branch.
  ///
  /// Four, whatever the machine. A push makes the host work — it checks the
  /// objects, runs its hooks and starts the pipelines of the repository —
  /// and a burst of pushes from one client is what its abuse limits look
  /// for.
  static int get pushes => _capped(4);

  /// For tasks that create something through the API of a git host: a pull
  /// request, a comment.
  ///
  /// Ten, whatever the machine. What a host limits here is not how many
  /// requests run at the same moment but how many **start** within a time:
  /// GitHub takes 80 requests that create content per minute and 500 per
  /// hour from one client and locks out whoever sends more (its »secondary
  /// rate limit«). That count is kept where the pull requests are created
  /// (gg_merge's `RequestLimit`), for the whole process — so this number
  /// only says how many are under way at once, and ten of them finish a
  /// minute's worth in a few seconds. GitHub recommends sending such
  /// requests one after the other; a request it turns away all the same is
  /// repeated after a wait.
  static int get pullRequests => _capped(10);

  /// For releases of repositories that go side by side: each brings its
  /// pushes, a pull request, the wait for its pipeline and an upload to a
  /// package registry.
  ///
  /// Four, whatever the machine: what the remotes take from one client
  /// without throttling it, and what a person can still follow. The heavy
  /// part of a release — its tests — is limited by [heavy] on top.
  static int get publishes => _capped(4);

  // ...........................................................................
  static int get _processors => max(1, ggPlatform.numberOfProcessors);

  /// The number [environmentVariable] holds; null when it holds none, or
  /// one below 1.
  static int? get _fromEnvironment {
    final value = int.tryParse(
      ggPlatform.environment[environmentVariable] ?? '',
    );
    return value == null || value < 1 ? null : value;
  }

  static int _capped(int limit) => min(limit, _fromEnvironment ?? limit);
}

/// Runs [count] tasks at the same time, at most [maxParallel] of them, and
/// reports as if they had run one after the other.
///
/// [task] gets the index of the task and the log to write to. What the first
/// unfinished task logs reaches [ggLog] right away; what the tasks after it
/// log is held back and follows once it is their turn. So the output reads
/// the same as that of a loop, lines that rewrite the line before them
/// included.
///
/// Returns the results in the order of the tasks.
///
/// When tasks fail, the error of the first failed one in the order of the
/// tasks is thrown, with its stack trace, and no further task is started.
/// What happens to the tasks that already run after the failed one depends on
/// [cancelOnError]:
///
/// - false: they finish and their output is logged, then the error is
///   thrown. For tasks that change something: nothing stops half way.
/// - true: they are cancelled — each task runs in a [GgProcessScope], which
///   kills the processes it started and refuses further ones — and neither
///   awaited nor logged. The error is thrown as soon as the tasks before the
///   failed one are done. For checks: a failure ends the run right away.
///   Wrap the steps of a task that must not stop half way in
///   [GgProcessScope.shield]. A process is not killed while git writes the
///   index of its working directory, see [waitForGitIndex].
Future<List<T>> runInParallel<T>({
  required int count,
  required Future<T> Function(int index, GgLog ggLog) task,
  required GgLog ggLog,
  required int maxParallel,
  bool cancelOnError = false,
}) => _ParallelRun<T>(
  count: count,
  task: task,
  ggLog: ggLog,
  maxParallel: max(1, maxParallel),
  cancelOnError: cancelOnError,
).run();

/// Lets only so many pieces of work run at the same time, however many
/// tasks are under way.
///
/// For tasks that are mostly light but may turn heavy: run all of them with
/// the limit of the light ones, and hand the heavy part to [use] of slots
/// shared by all of them. A light task then never waits behind a heavy one.
class TaskSlots {
  /// Constructor. [count] bodies run at the same time, at least one.
  TaskSlots(int count) : this._(count, false);

  /// Slots for the heavy part of tasks — a test run, an analyzer: as many
  /// as [GgParallelism.heavy] says.
  ///
  /// A body that holds one of them is told how much of the machine is its
  /// own: [GgParallelism.testFilesPerRun] and
  /// [GgParallelism.testTimeoutFactor] answer for these slots. Outside of
  /// them a test run is taken to have the machine for itself.
  TaskSlots.heavy() : this._(GgParallelism.heavy, true);

  TaskSlots._(int count, this._isHeavy)
    : _count = max(1, count),
      _free = max(1, count);

  // ...........................................................................
  /// Runs [body] as soon as a slot is free and returns its result. The
  /// bodies that wait get their slot in the order they asked for it.
  Future<T> use<T>(Future<T> Function() body) async {
    if (_free > 0) {
      _free--;
    } else {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }

    try {
      return await (_isHeavy
          ? runZoned(body, zoneValues: {_heavyKey: this})
          : body());
    } finally {
      // The slot goes straight to the next one waiting, if any.
      if (_waiting.isEmpty) {
        _free++;
      } else {
        _waiting.removeAt(0).complete();
      }
    }
  }

  // ...........................................................................
  /// Names the heavy slots a body runs in, for [GgParallelism].
  static final Object _heavyKey = Object();

  final int _count;
  final bool _isHeavy;
  int _free;
  final List<Completer<void>> _waiting = [];

  /// How many bodies hold a slot or wait for one, at most as many as there
  /// are slots: the bodies that share the machine, now or in a moment.
  int get _demand => min(_count, _count - _free + _waiting.length);
}

/// Waits until no git process writes the index of the repository in
/// [workingDirectory] anymore — at most [timeout], and not at all without a
/// directory.
///
/// For the moment before a process is killed: a test run may commit in the
/// repository it runs in, and killed in the middle of that it leaves
/// `.git/index.lock` behind, which makes every later git command in that
/// repository fail until someone removes the file by hand.
Future<void> waitForGitIndex(
  String? workingDirectory, {
  Duration timeout = const Duration(seconds: 5),
  Duration interval = const Duration(milliseconds: 50),
}) async {
  if (workingDirectory == null) {
    return;
  }

  final lock = File(path.join(workingDirectory, '.git', 'index.lock'));
  final stopwatch = Stopwatch()..start();
  while (lock.existsSync() && stopwatch.elapsed < timeout) {
    await Future<void>.delayed(interval);
  }
}

// .............................................................................
/// One call of [runInParallel].
class _ParallelRun<T> {
  _ParallelRun({
    required this.count,
    required this.task,
    required this.ggLog,
    required this.maxParallel,
    required this.cancelOnError,
  }) : _results = List<T?>.filled(count, null),
       _finished = List<bool>.filled(count, false),
       _held = List<List<String>>.generate(count, (_) => <String>[]),
       _scopes = List<GgProcessScope?>.filled(count, null);

  final int count;
  final Future<T> Function(int index, GgLog ggLog) task;
  final GgLog ggLog;
  final int maxParallel;
  final bool cancelOnError;

  final List<T?> _results;
  final List<bool> _finished;

  /// What the tasks logged that is not their turn yet.
  final List<List<String>> _held;
  final List<GgProcessScope?> _scopes;
  final Map<int, (Object, StackTrace)> _errors = {};
  final Completer<List<T>> _done = Completer<List<T>>();

  /// The task whose log goes straight to [ggLog].
  int _live = 0;

  /// The next task to start.
  int _next = 0;
  int _running = 0;

  /// The first failed task in the order of the tasks.
  int? _failed;

  // ...........................................................................
  Future<List<T>> run() {
    if (count == 0) {
      return Future.value(<T>[]);
    }
    _startTasks();
    return _done.future;
  }

  // ...........................................................................
  void _startTasks() {
    while (_running < maxParallel && _next < count && _failed == null) {
      _start(_next++);
    }
  }

  // ...........................................................................
  void _start(int index) {
    _running++;
    final scope = GgProcessScope(beforeKill: waitForGitIndex);
    _scopes[index] = scope;

    scope
        .run(() => Future.sync(() => task(index, (msg) => _log(index, msg))))
        .then(
          (result) {
            _results[index] = result;
            _onFinished(index);
          },
          onError: (Object error, StackTrace stackTrace) {
            _errors[index] = (error, stackTrace);
            _onFailed(index);
            _onFinished(index);
          },
        );
  }

  // ...........................................................................
  void _log(int index, String message) {
    if (_isDropped(index)) {
      return;
    }
    if (index == _live) {
      ggLog(message);
    } else {
      _held[index].add(message);
    }
  }

  // ...........................................................................
  /// A cancelled task has nothing to say anymore.
  bool _isDropped(int index) =>
      cancelOnError && _failed != null && index > _failed!;

  // ...........................................................................
  void _onFailed(int index) {
    if (_failed != null && _failed! < index) {
      return;
    }
    _failed = index;

    if (cancelOnError) {
      for (var i = index + 1; i < _next; i++) {
        _scopes[i]!.cancel();
      }
    }
  }

  // ...........................................................................
  void _onFinished(int index) {
    _running--;
    _finished[index] = true;
    _logWhoseTurnItIs();

    if (_done.isCompleted) {
      return;
    }

    final failed = _failed;
    if (failed == null) {
      if (_live == count) {
        _done.complete(_results.cast<T>());
      } else {
        _startTasks();
      }
      return;
    }

    // Every task before the failed one was started, tasks start in order.
    final isOver = cancelOnError
        ? _finished.take(failed).every((finished) => finished)
        : _running == 0;
    if (isOver) {
      final (error, stackTrace) = _errors[failed]!;
      _done.completeError(error, stackTrace);
    }
  }

  // ...........................................................................
  /// Moves on to the first unfinished task and logs what the tasks on the
  /// way there held back.
  void _logWhoseTurnItIs() {
    while (_live < count && _finished[_live]) {
      _live++;
      if (_live < count && !_isDropped(_live)) {
        _held[_live].forEach(ggLog);
        _held[_live].clear();
      }
    }
  }
}
