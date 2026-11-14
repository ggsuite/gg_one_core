// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_process/gg_process.dart';
import 'package:path/path.dart' as path;

/// What a lock file says: who holds the lock, and until when unless it is
/// renewed.
typedef RepoLease = ({String owner, DateTime expires});

/// Lets one piece of work at a time run in a repository — across the gg
/// processes of a machine.
///
/// Two runs that check the same repository at the same time — two
/// terminals, a developer and an agent — get in each other's way: both
/// delete and write the same coverage folder, the same generated files and
/// the same state file, and one of them fails for a reason that is not in
/// the code. With [use] the second run waits for the first.
///
/// The lock is a file in the `.git` folder of the repository ([fileName]),
/// so nothing git tracks or shows is touched. It names its holder and an
/// **expiry date**: the holder renews it every [renewEvery], and a lock
/// that is not renewed for [lifetime] is free again — whatever became of
/// the run that held it. No lock is ever left behind by a run that was
/// killed or hangs. A directory that is no repository is not protected.
class RepoLock {
  /// Constructor. A lock another run holds is asked for again every
  /// [pollInterval]. [now] is for tests.
  RepoLock({
    this.renewEvery = const Duration(seconds: 10),
    this.lifetime = const Duration(seconds: 30),
    this.pollInterval = const Duration(milliseconds: 250),
    this._now = DateTime.now,
  });

  /// The name of the lock file in the `.git` folder.
  static const String fileName = 'gg-run-lock';

  /// How often the holder of a lock renews it.
  final Duration renewEvery;

  /// How long a lock is held after it was taken or renewed. Longer than
  /// [renewEvery], so a renewal that comes late on a busy machine does not
  /// open the lock under a run that is still at work.
  final Duration lifetime;

  /// How often a lock another run holds is asked for.
  final Duration pollInterval;

  // ...........................................................................
  /// Runs [body] once no other run works in the repository in [directory]
  /// and returns its result.
  ///
  /// [body] learns whether it had to wait — another run may have done its
  /// work in the meantime. A caller that waits is told so once through
  /// [ggLog]. Code that holds the lock of a repository already — [use]
  /// called inside of [use] — runs right away.
  ///
  /// While [body] runs the lock is renewed every [renewEvery]. A wait ends
  /// with a [GgProcessCancelled] when the [GgProcessScope] of the caller is
  /// cancelled.
  Future<T> use<T>({
    required Directory directory,
    required GgLog ggLog,
    required Future<T> Function(bool waited) body,
  }) async {
    final file = fileOf(directory);
    if (file == null) {
      return body(false);
    }

    final held = Zone.current[_zoneKey] as Set<String>? ?? const <String>{};
    if (held.contains(file.path)) {
      return body(false);
    }

    final owner = '$pid-${_random.nextInt(1 << 32).toRadixString(16)}';
    final name = path.basename(path.normalize(path.absolute(directory.path)));
    final waited = await _take(file, owner, name, ggLog);
    if (waited == null) {
      // The lock file cannot be used: work without the lock rather than
      // not at all.
      return body(false);
    }

    var isLost = false;
    final renewal = Timer.periodic(renewEvery, (_) {
      if (!isLost && _renew(file, owner) == _Renewal.lost) {
        isLost = true;
        ggLog(
          cWarn(
            'The lock of this gg run on $name was not renewed in time, and '
            'another gg run took it. Both may work in $name now.',
          ),
        );
      }
    });

    try {
      return await runZoned(
        () => body(waited),
        zoneValues: {
          _zoneKey: {...held, file.path},
        },
      );
    } finally {
      renewal.cancel();
      await _release(file, owner);
    }
  }

  // ...........................................................................
  /// The lock file of the repository in [directory]: [fileName] in its
  /// `.git` folder — for a worktree or a submodule the folder its `.git`
  /// file names. Null when [directory] is not the root of a repository.
  static File? fileOf(Directory directory) {
    final dotGit = path.join(directory.path, '.git');
    final String? gitDir;

    switch (FileSystemEntity.typeSync(dotGit)) {
      case FileSystemEntityType.directory:
        gitDir = dotGit;
      case FileSystemEntityType.file:
        gitDir = _gitDirOf(File(dotGit));
      default:
        gitDir = null;
    }

    return gitDir == null
        ? null
        : File(path.canonicalize(path.join(gitDir, fileName)));
  }

  // ...........................................................................
  /// Who holds the lock in [file], and until when. Null when nobody does:
  /// no file, an empty one, or one that cannot be read.
  static RepoLease? leaseIn(File file) {
    try {
      return _parse(file.readAsStringSync());
    } on FileSystemException {
      return null;
    }
  }

  // ...........................................................................
  /// What a lock file holds for [lease].
  static String textOf(RepoLease lease) => jsonEncode({
    'owner': lease.owner,
    'expires': lease.expires.toUtc().toIso8601String(),
  });

  // ######################
  // Private
  // ######################

  final DateTime Function() _now;

  /// Names the locks the calling code holds, for [use] inside of [use].
  static final Object _zoneKey = Object();

  static final Random _random = Random();

  // ...........................................................................
  /// The folder a `.git` file points to with `gitdir: <path>`, null when it
  /// names none that exists.
  static String? _gitDirOf(File dotGit) {
    const prefix = 'gitdir:';
    for (final line in dotGit.readAsLinesSync()) {
      if (!line.startsWith(prefix)) {
        continue;
      }
      final gitDir = line.substring(prefix.length).trim();
      final resolved = path.isAbsolute(gitDir)
          ? gitDir
          : path.join(dotGit.parent.path, gitDir);
      return Directory(resolved).existsSync() ? resolved : null;
    }
    return null;
  }

  // ...........................................................................
  static RepoLease? _parse(String text) {
    try {
      final json = jsonDecode(text);
      if (json is! Map) {
        return null;
      }
      final owner = json['owner'];
      final expires = DateTime.tryParse('${json['expires']}');
      return owner is String && expires != null
          ? (owner: owner, expires: expires)
          : null;
    } on FormatException {
      return null;
    }
  }

  // ...........................................................................
  /// Takes the lock in [file] for [owner], waiting while another run holds
  /// it. Returns whether it had to wait — null when the file cannot be
  /// used as a lock at all.
  Future<bool?> _take(File file, String owner, String name, GgLog ggLog) async {
    var waited = false;

    while (true) {
      final taken = _change<bool?>(file, (lease, now) {
        final isFree = lease == null || !lease.expires.isAfter(now);
        return (
          write: isFree ? _leaseOf(owner, now) : null,
          // True: taken from a run that stopped renewing it.
          result: isFree ? lease != null : null,
        );
      });

      switch (taken) {
        case _Changed(result: final wasExpired?):
          if (waited && wasExpired) {
            ggLog(
              cDetail(
                'The other gg run did not renew its lock on $name for '
                '${lifetime.inSeconds}s. Going on without it.',
              ),
            );
          }
          return waited;
        case _Unusable():
          return null;
        case _Changed() || _Busy():
          // Another run holds the lock, or is at the file this moment.
          break;
      }

      if (taken is _Changed && !waited) {
        waited = true;
        ggLog(cDetail('Another gg run works in $name. Waiting for it …'));
      }
      GgProcessScope.current?.throwIfCancelled('wait', [
        'for',
        'another',
        'gg',
        'run',
      ]);
      await Future<void>.delayed(pollInterval);
    }
  }

  // ...........................................................................
  /// Moves the expiry date of the lock [owner] holds in [file] on. A lock
  /// that expired but was not taken is renewed all the same.
  _Renewal _renew(File file, String owner) {
    final renewed = _change<bool>(file, (lease, now) {
      final isOurs = lease == null || lease.owner == owner;
      return (write: isOurs ? _leaseOf(owner, now) : null, result: isOurs);
    });

    return switch (renewed) {
      _Changed(result: true) => _Renewal.renewed,
      _Changed() => _Renewal.lost,
      // The next renewal is in time as well.
      _ => _Renewal.skipped,
    };
  }

  // ...........................................................................
  /// Gives the lock [owner] holds in [file] back. A lock another run took
  /// in the meantime is left alone.
  Future<void> _release(File file, String owner) async {
    for (var attempt = 0; attempt < 40; attempt++) {
      final released = _change<bool>(file, (lease, now) {
        // An empty file: nobody holds the lock.
        final isOurs = lease != null && lease.owner == owner;
        return (write: isOurs ? '' : null, result: true);
      });
      if (released is! _Busy) {
        return;
      }

      // Another run is at the file this moment. Should it stay so, the
      // lock expires on its own.
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  // ...........................................................................
  /// What the lock file holds once [owner] took or renewed the lock at
  /// [now].
  String _leaseOf(String owner, DateTime now) =>
      textOf((owner: owner, expires: now.add(lifetime)));

  // ...........................................................................
  /// Reads the lock in [file], lets [decide] say what the file is to hold
  /// instead — null leaves it as it is —, and writes that: one step no
  /// other process can get in between.
  ///
  /// The step is guarded by a lock of the operating system on the file,
  /// held for these few lines only; within this process nothing gets in
  /// between because the step does not wait for anything.
  _Change<T> _change<T>(
    File file,
    ({String? write, T result}) Function(RepoLease? lease, DateTime now) decide,
  ) {
    final RandomAccessFile handle;
    try {
      handle = file.openSync(mode: FileMode.append);
    } on FileSystemException {
      return _Unusable<T>();
    }

    try {
      handle.lockSync(FileLock.exclusive);

      handle.setPositionSync(0);
      final text = utf8.decode(
        handle.readSync(handle.lengthSync()),
        allowMalformed: true,
      );

      final (:write, :result) = decide(_parse(text), _now().toUtc());
      if (write != null) {
        handle.truncateSync(0);
        handle.setPositionSync(0);
        handle.writeStringSync(write);
        handle.flushSync();
      }
      return _Changed<T>(result);
    } on FileSystemException {
      // Another process holds the file for its own step.
      return _Busy<T>();
    } finally {
      // Closing the file gives the lock of the operating system back.
      handle.closeSync();
    }
  }
}

// .............................................................................
/// What became of the renewal of a lock.
enum _Renewal { renewed, skipped, lost }

// .............................................................................
/// What became of a step at the lock file.
sealed class _Change<T> {}

/// The step was done; [result] is what it decided.
class _Changed<T> extends _Change<T> {
  _Changed(this.result);
  final T result;
}

/// Another process was at the file. Worth another try in a moment.
class _Busy<T> extends _Change<T> {}

/// The file cannot be opened: it is no use as a lock.
class _Unusable<T> extends _Change<T> {}
