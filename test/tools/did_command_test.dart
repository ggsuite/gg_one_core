// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_git/gg_git_test_helpers.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one_core/src/tools/did_command.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:test/test.dart';

void main() {
  late Directory d;
  late DidCommand didCommand;
  final messages = <String>[];

  // Strip the colors so the expectations stay readable. One closure
  // instance, not a function declaration: mocktail matches the ggLog
  // argument by identity, and a tear-off is not stable.
  // ignore: prefer_function_declarations_over_variables
  final GgLog ggLog = (String msg) => messages.add(rmControls(msg));

  // ...........................................................................
  void initDidCommand() {
    didCommand = DidCommand(
      name: 'do',
      description: 'description',
      shortDescription: 'Did do?',
      suggestion: 'Please run »gg do«.',
      ggLog: ggLog,
      stateKey: 'did-do',
    );
  }

  // ...........................................................................
  setUp(() async {
    messages.clear();
    d = Directory.systemTemp.createTempSync();
    await initGit(d);
    await addAndCommitSampleFile(d);
    initDidCommand();
  });

  // ...........................................................................
  tearDown(() {
    d.deleteSync(recursive: true);
  });

  // ...........................................................................
  group('DidCommand', () {
    group('exec(directory, ggLog)', () {
      group('should return true', () {
        group('and print ✓', () {
          test('when state was set to success before', () async {
            await didCommand.state.writeSuccess(directory: d, key: 'did-do');

            await didCommand.exec(directory: d, ggLog: ggLog);
            expect(messages[0], contains('⌛️ Did do?'));
            expect(messages[1], contains('✓ Did do?'));
          });
        });
      });

      group('should throw', () {
        group('and print ✗', () {
          test('when state was not set to success before', () async {
            // Getting the state should throw
            late String exceptionMessage;

            try {
              await didCommand.exec(directory: d, ggLog: ggLog);
            } catch (e) {
              exceptionMessage = e.toString();
            }

            expect(messages[0], contains('⌛️ Did do?'));
            expect(messages[1], contains('✗ Did do?'));
            // The exception carries its colors — strip them to compare.
            expect(rmControls(exceptionMessage), contains('Please run gg do.'));
          });
        });
      });
    });

    group('get(directory, ggLog)', () {
      group('should return', () {
        group('false', () {
          test('if something has changed inbetween', () async {
            await didCommand.state.writeSuccess(directory: d, key: 'did-do');

            await addAndCommitSampleFile(
              d,
              fileName: 'another-file.txt',
              content: 'another content',
            );

            final success = await didCommand.get(directory: d, ggLog: ggLog);

            expect(success, isFalse);
          });
        });

        group('true', () {
          test(
            'if a success state was saved and nothing has changed',
            () async {
              await didCommand.state.writeSuccess(directory: d, key: 'did-do');

              final success = await didCommand.get(directory: d, ggLog: ggLog);

              expect(success, isTrue);
            },
          );

          test(
            'if an unstaged file exists and ignoreUnstaged is true',
            () async {
              // Write success
              await didCommand.state.writeSuccess(directory: d, key: 'did-do');

              final success = await didCommand.get(directory: d, ggLog: ggLog);

              expect(success, isTrue);

              // Add a file without committing
              await addFileWithoutCommitting(d);

              final success2 = await didCommand.get(
                directory: d,
                ggLog: ggLog,
                ignoreUnstaged: true,
              );

              // Success is true, because ignoreUnstaged is true
              expect(success2, isTrue);

              final success3 = await didCommand.get(
                directory: d,
                ggLog: ggLog,
                ignoreUnstaged: false,
              );

              // Success is false, because ignoreUnstaged is false
              expect(success3, isFalse);
            },
          );
        });
      });
    });

    group('set(directory, ggLog)', () {
      test('should set the state to success', () async {
        await didCommand.set(directory: d);

        final success = await didCommand.get(directory: d, ggLog: ggLog);

        expect(success, isTrue);
      });
    });
  });
}
