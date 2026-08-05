// @license
// Copyright (c) 2019 - 2024 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_git/gg_git.dart';
import 'package:gg_git/gg_git_test_helpers.dart';
import 'package:gg_one_core/src/tools/gg_state.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:path/path.dart';
import 'package:test/test.dart';

void main() {
  late Directory dLocal;
  late Directory dRemote;
  late GgState ggState;
  final messages = <String>[];
  final ggLog = messages.add;
  late CommitCount commitCount;
  late ModifiedFiles modifiedFiles;

  // ...........................................................................
  setUp(() async {
    messages.clear();
    dLocal = await initTestDir();
    dRemote = await initTestDir();

    await initCachedRepo(
      dLocal,
      key: 'gg_state_local',
      build: (repo) async {
        await initGit(repo, isEolLfEnabled: false);

        // The former initCommand() called initGit a second time which
        // commits a .gitattributes file - keep the recipe verbatim so the
        // commit counts stay the same.
        await initGit(repo);
        await addPubspecFileWithoutCommitting(repo, version: '1.0.0');
        await commitPubspecFile(repo);
      },
    );
    await initCachedRepo(dRemote, key: 'gg_state_remote', build: initRemoteGit);

    ggState = GgState(ggLog: messages.add);
    commitCount = CommitCount(ggLog: messages.add);
    modifiedFiles = ModifiedFiles(ggLog: messages.add);
  });

  // ...........................................................................
  tearDown(() async {
    await dLocal.delete(recursive: true);
    await dRemote.delete(recursive: true);
  });

  // ...........................................................................
  group('CheckState', () {
    group('writeSuccess(directory, success)', () {
      group('with success == true', () {
        test('should write last change hash to .gg/gg.json', () async {
          await addAndCommitSampleFile(dLocal);

          // Get last changes hash
          final hash = await LastChangesHash(
            ggLog: messages.add,
          ).get(directory: dLocal, ggLog: messages.add);

          // Set the state
          await ggState.writeSuccess(directory: dLocal, key: 'can-commit');

          // Check the file
          final checkJson = File(join(dLocal.path, '.gg', 'gg.json'));
          await expectLater(await checkJson.exists(), isTrue);
          final contentsString = await checkJson.readAsString();
          final contents = json.decode(contentsString);
          expect(contents['can-commit']['success']['hash'], hash);
        });

        test('should prune obsolete keys from .gg/gg.json', () async {
          await addAndCommitSampleFile(dLocal);

          // A .gg.json written by an earlier gg version still carries
          // publish/merge states.
          final checkJson = File(join(dLocal.path, '.gg', 'gg.json'));
          checkJson.parent.createSync(recursive: true);
          checkJson.writeAsStringSync(
            '{"canCommit":{"success":{"hash":123}},'
            '"doPublish":{"success":{"hash":123}},'
            '"doPrepareVersion":{"success":{"hash":123}},'
            '"doPublishPubDev":{"success":{"hash":123}},'
            '"doPublishGit":{"success":{"hash":123}},'
            '"doMerge":{"success":{"hash":123}}}',
          );

          await ggState.writeSuccess(directory: dLocal, key: 'doCommit');

          final contents =
              json.decode(await checkJson.readAsString())
                  as Map<String, dynamic>;
          for (final key in GgState.obsoleteKeys) {
            expect(contents.containsKey(key), isFalse, reason: key);
          }
          expect(contents.containsKey('canCommit'), isTrue);
          expect(contents.containsKey('doCommit'), isTrue);
        });

        test('should prune only once per directory', () async {
          await addAndCommitSampleFile(dLocal);

          final checkJson = File(join(dLocal.path, '.gg', 'gg.json'));
          checkJson.parent.createSync(recursive: true);
          checkJson.writeAsStringSync('{"doPublish":{"success":{"hash":1}}}');

          await ggState.writeSuccess(directory: dLocal, key: 'doCommit');

          // Re-introduce an obsolete key — the per-process memo skips a
          // second pruning read on this hot path.
          final contents1 =
              json.decode(await checkJson.readAsString())
                  as Map<String, dynamic>;
          contents1['doPublish'] = {
            'success': {'hash': 2},
          };
          checkJson.writeAsStringSync(json.encode(contents1));

          await ggState.writeSuccess(directory: dLocal, key: 'canPush');

          final contents2 =
              json.decode(await checkJson.readAsString())
                  as Map<String, dynamic>;
          expect(contents2.containsKey('doPublish'), isTrue);
          expect(contents2.containsKey('canPush'), isTrue);
        });

        test('should tolerate an empty .gg/gg.json when pruning', () async {
          await addAndCommitSampleFile(dLocal);

          final checkJson = File(join(dLocal.path, '.gg', 'gg.json'));
          checkJson.parent.createSync(recursive: true);
          checkJson.writeAsStringSync('');

          await ggState.writeSuccess(directory: dLocal, key: 'doCommit');

          final contents =
              json.decode(await checkJson.readAsString())
                  as Map<String, dynamic>;
          expect(contents.containsKey('doCommit'), isTrue);
        });

        test('should leave .gg/gg.json untouched when no obsolete '
            'keys exist', () async {
          await addAndCommitSampleFile(dLocal);

          await ggState.writeSuccess(directory: dLocal, key: 'canCommit');
          await ggState.writeSuccess(directory: dLocal, key: 'doCommit');

          final checkJson = File(join(dLocal.path, '.gg', 'gg.json'));
          final contents =
              json.decode(await checkJson.readAsString())
                  as Map<String, dynamic>;
          expect(contents.keys, containsAll(<String>['canCommit', 'doCommit']));
        });
      });

      group('should ammend changes to .gg/gg.json to the last commit', () {
        test('when previous changes were not already pushed', () async {
          // Let's create an inital commit
          await addAndCommitSampleFile(dLocal, fileName: 'file1.txt');

          // Check the inital commit count
          final initialCommitCount = await commitCount.get(
            directory: dLocal,
            ggLog: ggLog,
          );
          expect(initialCommitCount, 3);

          // file1.txt should be shown as modified in the last commit
          expect(
            await modifiedFiles.get(
              directory: dLocal,
              ggLog: ggLog,
              force: true,
            ),
            ['file1.txt'],
          );

          // Run the command a first time
          await ggState.writeSuccess(directory: dLocal, key: 'isCommitted');

          // Because we have not pushed the changes yet,
          // changes to gg.json should be ammended to the last commit

          // - i.e. commit count has not changed
          final commitCount0 = await commitCount.get(
            directory: dLocal,
            ggLog: ggLog,
          );
          expect(commitCount0, 3);

          // - i.e. file1.txt should be shown as modified in the last commit
          expect(
            await modifiedFiles.get(
              directory: dLocal,
              ggLog: ggLog,
              force: true,
            ),
            ['.gg/gg.json', 'file1.txt'],
          );
        });
      });

      group('should create a new commit', () {
        test('when previous changes were already pushed', () async {
          // Let's connect the local and remote repositories
          await addRemoteToLocal(local: dLocal, remote: dRemote);

          // Let's create an inital commit
          await addAndCommitSampleFile(dLocal, fileName: 'file1.txt');

          // Check the inital commit count
          final initialCommitCount = await commitCount.get(
            directory: dLocal,
            ggLog: ggLog,
          );
          expect(initialCommitCount, isNot(0));

          // file1.txt should be shown as modified in the last commit
          expect(
            await modifiedFiles.get(
              directory: dLocal,
              ggLog: ggLog,
              force: true,
            ),
            ['file1.txt'],
          );

          // Push the changes
          await Process.run('git', ['push'], workingDirectory: dLocal.path);

          // Run the command a first time
          await ggState.writeSuccess(directory: dLocal, key: 'isCommitted');

          // Because we have pushed the changes already,
          // changes to gg.json should be commited as a new commit

          // - i.e. commit count has changed
          final commitCount0 = await commitCount.get(
            directory: dLocal,
            ggLog: ggLog,
          );
          expect(commitCount0, initialCommitCount + 1);

          // - i.e. only .gg/gg.json should be shown as modified in the last
          //   commit
          expect(
            await modifiedFiles.get(
              directory: dLocal,
              ggLog: ggLog,
              force: true,
            ),
            ['.gg/gg.json'],
          );

          // Executing the cluster again should not change anything
          await ggState.writeSuccess(directory: dLocal, key: 'isCommitted');

          final commitCount1 = await commitCount.get(
            directory: dLocal,
            ggLog: ggLog,
          );
          expect(commitCount1, initialCommitCount + 1);
        });
      });

      group('should throw', () {
        test('if nothing is comitted', () async {
          await dLocal.delete(recursive: true);
          dLocal = await initTestDir();
          await initGit(dLocal, isEolLfEnabled: false);

          expect(
            () async => await ggState.writeSuccess(
              directory: dLocal,
              key: 'isCommitted',
            ),
            throwsA(
              isA<Exception>().having(
                (e) => rmControls(e.toString()),
                'toString()',
                'Exception: '
                    'There must be at least one commit in the repository.',
              ),
            ),
          );
        });
      });
    });

    group('readSuccess(directory, key, ggLog)', () {
      group('should return', () {
        group('false', () {
          test('if no .gg/gg.json exists', () async {
            expect(
              await File(join(dLocal.path, '.gg', 'gg.json')).exists(),
              isFalse,
            );
            final result = await ggState.readSuccess(
              directory: dLocal,
              ggLog: messages.add,
              key: 'can-commit',
            );
            expect(result, isFalse);
          });

          test('if .gg/gg.json is empty', () async {
            final ggDir = Directory(join(dLocal.path, '.gg'));
            if (!ggDir.existsSync()) {
              ggDir.createSync(recursive: true);
            }
            File(join(dLocal.path, '.gg', 'gg.json')).writeAsStringSync('{}');

            final result = await ggState.readSuccess(
              directory: dLocal,
              ggLog: messages.add,
              key: 'can-commit',
            );
            expect(result, isFalse);
          });

          test('if last success hash is not current hash', () async {
            // Set the state
            await ggState.writeSuccess(directory: dLocal, key: 'can-commit');

            // Change the file
            await addAndCommitSampleFile(dLocal);

            final result = await ggState.readSuccess(
              directory: dLocal,
              ggLog: messages.add,
              key: 'can-commit',
            );
            expect(result, isFalse);
          });
        });

        group('true', () {
          test('if last success hash is current hash', () async {
            // Commit something
            await addAndCommitSampleFile(dLocal, fileName: 'file0.txt');

            // Write success after everything is committed
            await ggState.writeSuccess(directory: dLocal, key: 'can-commit');

            // Read succes -> It should be true
            final result = await ggState.readSuccess(
              directory: dLocal,
              ggLog: messages.add,
              key: 'can-commit',
            );
            expect(result, isTrue);

            // Make a modification
            await File('${dLocal.path}/file0.txt').writeAsString('modified');

            // Read success -> It should be false
            final result2 = await ggState.readSuccess(
              directory: dLocal,
              ggLog: messages.add,
              key: 'can-commit',
            );
            expect(result2, isFalse);

            // Write success again
            await ggState.writeSuccess(directory: dLocal, key: 'can-commit');

            // Read success -> It should be true
            final result3 = await ggState.readSuccess(
              directory: dLocal,
              ggLog: messages.add,
              key: 'can-commit',
            );
            expect(result3, isTrue);

            // Commit the last changes.
            // This should not change the success state.
            await commitFile(dLocal, 'file0.txt');

            // Read success -> It should be true
            final result4 = await ggState.readSuccess(
              directory: dLocal,
              ggLog: messages.add,
              key: 'can-commit',
            );
            expect(result4, isTrue);
          });
        });
      });
    });

    group('updateHash()', () {
      group('replaces the hash in .gg/gg.json with the current hash', () {
        test('when current hash is different', () async {
          // Get last changes hash
          final hash = await LastChangesHash(
            ggLog: messages.add,
          ).get(directory: dLocal, ggLog: messages.add);

          // Set the state
          await ggState.writeSuccess(directory: dLocal, key: 'can-commit');

          // Change the file
          await addAndCommitSampleFile(dLocal);

          // Because of the change, ggState.readSuccess should return false
          final result = await ggState.readSuccess(
            directory: dLocal,
            ggLog: messages.add,
            key: 'can-commit',
          );
          expect(result, isFalse);

          // Update the previous hash
          await ggState.updateHash(hash: hash, directory: dLocal);

          // Now ggState.readSuccess should return true again
          final result1 = await ggState.readSuccess(
            directory: dLocal,
            ggLog: messages.add,
            key: 'can-commit',
          );
          expect(result1, isTrue);
        });

        test('but not when the hash has not changed', () async {
          // Get last changes hash
          final hash = await LastChangesHash(
            ggLog: messages.add,
          ).get(directory: dLocal, ggLog: messages.add);

          // Update the previous hash
          await ggState.updateHash(hash: hash, directory: dLocal);
        });
      });
    });

    group('reset(directory)', () {
      test('should reset success state', () async {
        // Set the state
        await ggState.writeSuccess(directory: dLocal, key: 'can-commit');

        expect(
          await ggState.readSuccess(
            directory: dLocal,
            ggLog: messages.add,
            key: 'can-commit',
          ),
          isTrue,
        );

        // Reset the state
        await ggState.reset(directory: dLocal);

        // Check the file
        expect(
          await ggState.readSuccess(
            directory: dLocal,
            ggLog: messages.add,
            key: 'can-commit',
          ),
          isFalse,
        );
      });
    });

    group('migration of the hidden state file', () {
      test('renames .gg/.gg.json to .gg/gg.json and keeps the state', () async {
        await ggState.writeSuccess(directory: dLocal, key: 'can-commit');

        // Turn the state file back into what an earlier gg version wrote.
        final ggDir = Directory(join(dLocal.path, '.gg'));
        final current = File(join(ggDir.path, GgState.configFileName));
        final legacy = File(join(ggDir.path, GgState.legacyConfigFileName));
        current.renameSync(legacy.path);
        expect(current.existsSync(), isFalse);

        expect(
          await ggState.readSuccess(
            directory: dLocal,
            ggLog: messages.add,
            key: 'can-commit',
          ),
          isTrue,
        );
        expect(current.existsSync(), isTrue);
        expect(legacy.existsSync(), isFalse);
      });

      test(
        'keeps the current state file when a hidden one also exists',
        () async {
          await ggState.writeSuccess(directory: dLocal, key: 'can-commit');

          final ggDir = Directory(join(dLocal.path, '.gg'));
          final current = File(join(ggDir.path, GgState.configFileName));
          final currentContent = current.readAsStringSync();
          File(
            join(ggDir.path, GgState.legacyConfigFileName),
          ).writeAsStringSync('{}');

          expect(
            await ggState.readSuccess(
              directory: dLocal,
              ggLog: messages.add,
              key: 'can-commit',
            ),
            isTrue,
          );
          expect(current.readAsStringSync(), currentContent);
        },
      );
    });
  });
}
