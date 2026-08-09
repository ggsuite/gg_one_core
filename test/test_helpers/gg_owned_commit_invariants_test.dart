// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_git/gg_git_test_helpers.dart';
import 'package:gg_one_core/gg_one_core_test_helpers.dart';
import 'package:test/test.dart';

void main() {
  late Directory d;

  setUp(() async {
    d = await initTestDir();
    await initGit(d);
  });

  tearDown(() async {
    await d.delete(recursive: true);
  });

  group('expectGgCommitsTouchOnlyGgFiles(repo)', () {
    test('passes when every gg commit only touches gg-owned files', () async {
      await addAndCommitSampleFile(d, fileName: 'lib.dart', content: 'user');
      await addAndCommitSampleFile(
        d,
        fileName: 'pubspec.lock',
        content: 'generated',
        message: '#gg: Update pubspec.lock',
      );

      await expectGgCommitsTouchOnlyGgFiles(d);
    });

    test('ignores user commits touching arbitrary files', () async {
      await addAndCommitSampleFile(d, fileName: 'lib.dart', content: 'user');

      await expectGgCommitsTouchOnlyGgFiles(d);
    });

    test('throws when a gg commit swallowed a user file', () async {
      await addAndCommitSampleFile(
        d,
        fileName: 'lib.dart',
        content: 'user work',
        message: '#gg: changed references to pub.dev',
      );

      await expectLater(
        expectGgCommitsTouchOnlyGgFiles(d),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('lib.dart'), contains('swallowed user work')),
          ),
        ),
      );
    });

    test('ignores commits before »since«', () async {
      await addAndCommitSampleFile(
        d,
        fileName: 'lib.dart',
        content: 'old sin',
        message: '#gg: swallowed before the rule existed',
      );
      final rev = await Process.run('git', [
        'rev-parse',
        'HEAD',
      ], workingDirectory: d.path);
      final since = rev.stdout.toString().trim();

      await addAndCommitSampleFile(
        d,
        fileName: 'pubspec.lock',
        content: 'generated',
        message: '#gg: Update pubspec.lock',
      );

      await expectGgCommitsTouchOnlyGgFiles(d, since: since);
      await expectLater(
        expectGgCommitsTouchOnlyGgFiles(d),
        throwsA(isA<Exception>()),
      );
    });

    test('throws when the history cannot be read', () async {
      final empty = await initTestDir();
      await Process.run('git', [
        'init',
        '--initial-branch=main',
      ], workingDirectory: empty.path);

      await expectLater(
        expectGgCommitsTouchOnlyGgFiles(empty),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Could not read the history'),
          ),
        ),
      );
    });
  });
}
