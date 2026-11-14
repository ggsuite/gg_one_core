// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_git/gg_git.dart';
import 'package:gg_git/gg_git_test_helpers.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_publish/gg_publish.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart';
import 'package:test/test.dart';

void main() {
  late Directory d;
  final messages = <String>[];
  // Strip the colors so the expectations stay readable. One closure
  // instance, not a function declaration: mocktail matches the ggLog
  // argument by identity, and a tear-off is not stable.
  // ignore: prefer_function_declarations_over_variables
  final GgLog ggLog = (String msg) => messages.add(rmControls(msg));
  late IsCommitted isCommitted;
  late IsPushed isPushed;
  late IsUpgraded isUpgraded;

  late List<DirCommand<void>> commands;
  late CommandCluster commandCluster;

  setUp(() async {
    // Init basics
    messages.clear();
    d = Directory.systemTemp.createTempSync();
    await initGit(d);

    // Init commands
    isCommitted = MockIsCommitted();
    isPushed = MockIsPushed();
    isUpgraded = MockIsUpgraded();
    commands = [isCommitted, isPushed, isUpgraded];

    // Init command cluster
    commandCluster = CommandCluster(
      ggLog: ggLog,
      commands: commands,
      name: 'my-check',
      description: 'A more detailed description.',
      shortDescription: 'Do all check commands work?',
      stateKey: 'my-check',
    );

    // Mock the commands
    when(() => isCommitted.exec(directory: d, ggLog: ggLog))
        .thenAnswer((_) async {
          ggLog('isCommitted');
          return true;
        });
    when(() => isPushed.exec(directory: d, ggLog: ggLog)).thenAnswer((_) async {
      ggLog('isPushed');
      return true;
    });
    when(() => isUpgraded.exec(directory: d, ggLog: ggLog))
        .thenAnswer((_) async {
          ggLog('isUpgraded');
          return true;
        });
  });

  tearDown(() async {
    await d.delete(recursive: true);
  });

  group('CommandCluster', () {
    group('with checksSetting', () {
      test('skips the commands when enableChecks is false', () async {
        GgRc.repoFileOf(d)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('{"can": {"commit": {"checks": false}}}');
        final cluster = CommandCluster(
          ggLog: ggLog,
          commands: commands,
          name: 'commit',
          description: 'Skippable.',
          shortDescription: 'Skippable?',
          stateKey: 'skippable',
          checksSetting: GgRc.commitChecks,
        );
        await cluster.exec(directory: d, ggLog: ggLog);
        expect(messages, [
          'Skippable? skipped: can.commit.checks is false in .gg/gg_rc.',
        ]);
      });

      test('runs the commands when enableChecks is true', () async {
        final cluster = CommandCluster(
          ggLog: ggLog,
          commands: commands,
          name: 'commit',
          description: 'Skippable.',
          shortDescription: 'Skippable?',
          stateKey: 'skippable',
          checksSetting: GgRc.commitChecks,
        );
        await cluster.exec(directory: d, ggLog: ggLog);
        expect(messages, ['isCommitted', 'isPushed', 'isUpgraded']);
        expect(GgRc.repoFileOf(d).existsSync(), isFalse);
      });
    });

    group('when another gg run works in the repository', () {
      /// A lock that asks often, shared by the cluster and the other run.
      final lock = RepoLock(pollInterval: const Duration(milliseconds: 5));
      late CommandCluster cluster;

      setUp(() {
        cluster = CommandCluster(
          ggLog: ggLog,
          commands: commands,
          name: 'my-check',
          description: 'A more detailed description.',
          shortDescription: 'Do all check commands work?',
          stateKey: 'my-check',
          repoLock: lock,
        );
      });

      /// Runs the cluster while another run holds the lock of the
      /// repository. With [checksTheSameState] the other run records the
      /// success the cluster is after before it gives the lock back.
      Future<void> runNextToAnotherRun({
        required bool checksTheSameState,
        bool force = false,
      }) async {
        final otherIsDone = Completer<void>();
        final other = lock.use(
          directory: d,
          ggLog: (_) {},
          body: (_) async {
            await otherIsDone.future;
            if (checksTheSameState) {
              await GgState(ggLog: (_) {})
                  .writeSuccess(directory: d, key: 'my-check');
            }
          },
        );

        final run = cluster.exec(directory: d, ggLog: ggLog, force: force);

        // The cluster finds the lock taken as soon as it knows that its
        // state is not recorded — and runs nothing while it waits.
        while (messages.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(messages, [
          'Another gg run works in ${basename(d.path)}. Waiting for it …',
        ]);

        otherIsDone.complete();
        await other;
        await run;
      }

      test('waits for it and takes over its result', () async {
        await runNextToAnotherRun(checksTheSameState: true);

        // What the other run checked is not checked again.
        expect(messages.skip(1), ['✓ Do all check commands work?']);
      });

      test('waits for it and runs its commands when the other run checked '
          'something else', () async {
        await runNextToAnotherRun(checksTheSameState: false);

        expect(messages.skip(1), ['isCommitted', 'isPushed', 'isUpgraded']);
      });

      test('waits for it and runs its commands all the same when '
          'forced', () async {
        await runNextToAnotherRun(checksTheSameState: true, force: true);

        expect(messages.skip(1), ['isCommitted', 'isPushed', 'isUpgraded']);
      });
    });

    group('exec(directory, log)', () {
      group('with force == false', () {
        test(
          'should not run commands again that were successful before',
          () async {
            // Run the command a first time
            // Should complain about missing commits
            await commandCluster.exec(directory: d, ggLog: ggLog);

            expect(messages[0], 'isCommitted');
            expect(messages[1], 'isPushed');
            expect(messages[2], 'isUpgraded');

            // Make an initial commit
            await addAndCommitSampleFile(d, fileName: 'file1.txt');

            // Run command again
            await commandCluster.exec(directory: d, ggLog: ggLog);
            expect(messages[3], 'isCommitted');
            expect(messages[4], 'isPushed');
            expect(messages[5], 'isUpgraded');

            // Run the command a second time.
            // Should not run the commands again,
            // because force is false
            // and the commands were successful before.
            // The already-done line names the cluster.
            await commandCluster.exec(directory: d, ggLog: ggLog);
            expect(messages[6], '✓ Do all check commands work?');
          },
        );
      });

      group('with force == true', () {
        test('should run commands '
            'no matter if they were successful before or not', () async {
          await addAndCommitSampleFile(d, fileName: 'file1.txt');

          // Run the command a first time
          await commandCluster.exec(directory: d, ggLog: ggLog);
          expect(messages[0], 'isCommitted');
          expect(messages[1], 'isPushed');
          expect(messages[2], 'isUpgraded');

          // Run the command a second first time
          await commandCluster.exec(directory: d, ggLog: ggLog, force: true);
          expect(messages[3], 'isCommitted');
          expect(messages[4], 'isPushed');
          expect(messages[5], 'isUpgraded');
        });
      });

      group('with save-state == true or (false)', () {
        test('should (not) save the success state', () async {
          await addAndCommitSampleFile(d, fileName: 'file1.txt');

          final ggDir = Directory(join(d.path, '.gg'));
          if (!ggDir.existsSync()) {
            ggDir.createSync(recursive: true);
          }
          final ggJson = await File(join(ggDir.path, 'gg.json')).create();
          final ggJsonBefore = await ggJson.readAsString();

          // Run the command with save-state == false
          await commandCluster.exec(
            directory: d,
            ggLog: ggLog,
            force: true,
            saveState: false,
          );

          // State should not be saved
          final ggJsonAfterWithoutSave = await ggJson.readAsString();
          expect(ggJsonAfterWithoutSave, ggJsonBefore);

          // Run the command with save-state == true
          await commandCluster.exec(
            directory: d,
            ggLog: ggLog,
            force: true,
            saveState: true,
          );

          // State should be saved
          final ggJsonAfterWithSave = await ggJson.readAsString();
          expect(ggJsonBefore, isNot(ggJsonAfterWithSave));
        });
      });
    });
  });
}
