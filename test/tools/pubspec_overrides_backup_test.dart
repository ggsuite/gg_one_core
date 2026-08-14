// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_one_core/gg_one_core.dart';
import 'package:path/path.dart';
import 'package:test/test.dart';

void main() {
  late Directory d;

  File overridesFile() => File(join(d.path, NoPubspecOverrides.fileName));

  File backupFile() => File(join(d.path, pubspecOverridesBackupPath));

  setUp(() {
    d = Directory.systemTemp.createTempSync('pubspec_overrides_backup_test');
  });

  tearDown(() {
    d.deleteSync(recursive: true);
  });

  group('backupPubspecOverrides', () {
    test('copies the overrides file into .gg and reports true', () {
      overridesFile().writeAsStringSync('dependency_overrides:\n');

      final didBackup = backupPubspecOverrides(d);

      expect(didBackup, isTrue);
      expect(backupFile().existsSync(), isTrue);
      expect(backupFile().readAsStringSync(), 'dependency_overrides:\n');
      // The original stays — deleting it is the publish flow's decision.
      expect(overridesFile().existsSync(), isTrue);
    });

    test('overwrites an existing backup with the current overrides', () {
      backupFile().parent.createSync(recursive: true);
      backupFile().writeAsStringSync('stale');
      overridesFile().writeAsStringSync('current');

      final didBackup = backupPubspecOverrides(d);

      expect(didBackup, isTrue);
      expect(backupFile().readAsStringSync(), 'current');
    });

    test('does nothing without an overrides file', () {
      backupFile().parent.createSync(recursive: true);
      backupFile().writeAsStringSync('previous');

      final didBackup = backupPubspecOverrides(d);

      expect(didBackup, isFalse);
      // A previous backup is kept — there is nothing newer to save.
      expect(backupFile().readAsStringSync(), 'previous');
    });
  });

  group('restorePubspecOverrides', () {
    test('restores the overrides file and deletes the backup', () {
      backupFile().parent.createSync(recursive: true);
      backupFile().writeAsStringSync('dependency_overrides:\n');

      final didRestore = restorePubspecOverrides(d);

      expect(didRestore, isTrue);
      expect(overridesFile().existsSync(), isTrue);
      expect(overridesFile().readAsStringSync(), 'dependency_overrides:\n');
      expect(backupFile().existsSync(), isFalse);
    });

    test('overwrites an existing overrides file with the backup', () {
      overridesFile().writeAsStringSync('post publish');
      backupFile().parent.createSync(recursive: true);
      backupFile().writeAsStringSync('pre publish');

      final didRestore = restorePubspecOverrides(d);

      expect(didRestore, isTrue);
      expect(overridesFile().readAsStringSync(), 'pre publish');
    });

    test('does nothing without a backup', () {
      final didRestore = restorePubspecOverrides(d);

      expect(didRestore, isFalse);
      expect(overridesFile().existsSync(), isFalse);
    });
  });

  group('round trip', () {
    test('backup + delete + restore reproduces the original file', () {
      overridesFile().writeAsStringSync('dependency_overrides:\n  a:\n');

      backupPubspecOverrides(d);
      overridesFile().deleteSync();
      final didRestore = restorePubspecOverrides(d);

      expect(didRestore, isTrue);
      expect(
        overridesFile().readAsStringSync(),
        'dependency_overrides:\n  a:\n',
      );
      expect(backupFile().existsSync(), isFalse);
    });
  });

  group('pnpm-workspace.yaml', () {
    File pnpmWorkspaceFile() => File(join(d.path, 'pnpm-workspace.yaml'));

    File pnpmBackupFile() => File(join(d.path, pnpmWorkspaceBackupPath));

    test('is backed up and restored alongside the Dart overrides', () {
      pnpmWorkspaceFile().writeAsStringSync(
        'overrides:\n  dep_a: link:../dep_a\n',
      );

      final didBackup = backupPubspecOverrides(d);
      expect(didBackup, isTrue);
      expect(pnpmBackupFile().existsSync(), isTrue);

      // Simulate the unlocalization deleting the gg-created file.
      pnpmWorkspaceFile().deleteSync();

      final didRestore = restorePubspecOverrides(d);
      expect(didRestore, isTrue);
      expect(
        pnpmWorkspaceFile().readAsStringSync(),
        'overrides:\n  dep_a: link:../dep_a\n',
      );
      expect(pnpmBackupFile().existsSync(), isFalse);
    });

    test('a TypeScript repo without the file reports false', () {
      expect(backupPubspecOverrides(d), isFalse);
      expect(restorePubspecOverrides(d), isFalse);
    });
  });
}
