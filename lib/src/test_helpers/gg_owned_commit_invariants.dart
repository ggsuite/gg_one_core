// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_one_core/src/tools/gg_commit_message.dart';
import 'package:gg_one_core/src/tools/gg_owned_files.dart';

/// Throws when a »#gg: « commit of [repo] touches a file gg does not own.
///
/// This is the write-side twin of the check `PublishSkipCheck` performs when
/// it reads history: a bookkeeping commit containing anything beyond gg's own
/// files has swallowed user work. Integration tests run this after driving a
/// flow, so the invariant is verified against real git history — not only
/// against the units that are supposed to uphold it.
///
/// [since] limits the range to the commits after the given rev — for checks
/// against long real histories that predate the invariant.
Future<void> expectGgCommitsTouchOnlyGgFiles(
  Directory repo, {
  String? since,
}) async {
  final range = since == null ? 'HEAD' : '$since..HEAD';
  final log = await Process.run('git', [
    'log',
    '--no-merges',
    '--format=%H%x09%s',
    range,
  ], workingDirectory: repo.path);
  if (log.exitCode != 0) {
    throw Exception('Could not read the history of $range: ${log.stderr}');
  }

  for (final line in log.stdout.toString().split('\n')) {
    final entry = line.trim();
    if (entry.isEmpty) {
      continue;
    }
    final tab = entry.indexOf('\t');
    final hash = tab < 0 ? entry : entry.substring(0, tab);
    final subject = tab < 0 ? '' : entry.substring(tab + 1);

    if (!isGgGenerated(subject)) {
      continue;
    }

    final show = await Process.run('git', [
      'show',
      '--name-only',
      '--format=',
      hash,
    ], workingDirectory: repo.path);
    // A hash git log just printed cannot vanish before git show reads it —
    // the guard exists for corrupted repositories only.
    if (show.exitCode != 0) {
      // coverage:ignore-start
      throw Exception('Could not inspect commit $hash: ${show.stderr}');
      // coverage:ignore-end
    }

    for (final fileLine in show.stdout.toString().split('\n')) {
      final file = fileLine.trim();
      if (file.isEmpty || isGgOwnedPath(file)) {
        continue;
      }
      throw Exception(
        'The gg commit »$subject« ($hash) touches »$file«, which gg does '
        'not own — it swallowed user work.',
      );
    }
  }
}
