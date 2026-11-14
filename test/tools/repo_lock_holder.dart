// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// A process of its own for repo_lock_test.dart: what another gg run, or
// another process at the lock file, looks like from outside.
//
//   dart repo_lock_holder.dart use <repo> <renewEvery ms> <lifetime ms>
//     Holds the lock of <repo> like a gg run and prints »holding« once it
//     has it. The line »release« on stdin makes it give the lock back; the
//     line »die« ends the process on the spot, as if it had been killed:
//     the lock is not given back and not renewed anymore.
//
//   dart repo_lock_holder.dart file <lock file>
//     Locks the lock file through the operating system, as a process does
//     for the moment it reads and writes the file. Prints »locked« and
//     unlocks when a line arrives on stdin.

import 'dart:convert';
import 'dart:io';

import 'package:gg_one_core/src/tools/repo_lock.dart';

Future<void> main(List<String> args) async {
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());

  switch (args.first) {
    case 'use':
      final lock = RepoLock(
        renewEvery: Duration(milliseconds: int.parse(args[2])),
        lifetime: Duration(milliseconds: int.parse(args[3])),
        pollInterval: const Duration(milliseconds: 10),
      );
      await lock.use<void>(
        directory: Directory(args[1]),
        ggLog: stderr.writeln,
        body: (_) async {
          stdout.writeln('holding');
          if (await lines.first == 'die') {
            exit(3);
          }
        },
      );

    case 'file':
      final handle = File(args[1]).openSync(mode: FileMode.append);

      // The run under test may be at the file this very moment, for a
      // renewal: its turn first.
      while (true) {
        try {
          handle.lockSync(FileLock.exclusive);
          break;
        } on FileSystemException {
          sleep(const Duration(milliseconds: 5));
        }
      }
      stdout.writeln('locked');
      await lines.first;
      handle.closeSync();
  }

  stdout.writeln('done');
  await stdout.flush();
  exit(0);
}
