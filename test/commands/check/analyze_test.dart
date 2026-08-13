// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gg_capture_print/gg_capture_print.dart';
import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

void main() {
  final messages = <String>[];
  late CommandRunner<void> runner;
  late Directory tmpDir;

  setUpAll(() {
    registerFallbackValue(Directory(''));
  });

  setUp(() {
    messages.clear();
    runner = CommandRunner<void>('test', 'test');
    runner.addCommand(Analyze(ggLog: messages.add));
    tmpDir = Directory.systemTemp.createTempSync();
    // A valid pubspec.yaml makes `detectProjectType` return ProjectType.dart.
    File('${tmpDir.path}/pubspec.yaml').writeAsStringSync('name: foo\n');
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  group('Analyze', () {
    group('run()', () {
      // .......................................................................
      group('should print a usage description', () {
        test('when called with args=[--help]', () async {
          await capturePrint(
            ggLog: messages.add,
            code: () => runner.run(['analyze', '--help']),
          );

          expect(messages.last, contains('Runs static analysis.'));
        });
      });

      // .......................................................................
      group('should throw', () {
        test('if input is missing', () async {
          await expectLater(
            runner.run(['analyze', '--input=some-unknown-dir']),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.message,
                'message',
                contains('Directory "some-unknown-dir" does not exist.'),
              ),
            ),
          );
        });

        test('if the underlying analyzer fails', () async {
          final mockAnalyzer = MockAnalyzer();
          when(
            () => mockAnalyzer.run(
              directory: any(named: 'directory'),
              ggLog: any(named: 'ggLog'),
            ),
          ).thenThrow(Exception('boom'));

          final localRunner = CommandRunner<void>('test', 'test');
          localRunner.addCommand(
            Analyze(ggLog: messages.add, dartAnalyzer: mockAnalyzer),
          );

          await expectLater(
            () => localRunner.run(['analyze', '--input', tmpDir.path]),
            throwsA(
              isA<Exception>().having(
                (e) => rmControls(e.toString()),
                'message',
                contains('boom'),
              ),
            ),
          );
        });

        test('when the injected typescript analyzer throws', () async {
          final tsDir = Directory.systemTemp.createTempSync();
          File('${tsDir.path}/package.json').writeAsStringSync('{}');
          File('${tsDir.path}/tsconfig.json').writeAsStringSync('{}');
          final mockAnalyzer = MockAnalyzer();
          when(
            () => mockAnalyzer.run(
              directory: any(named: 'directory'),
              ggLog: any(named: 'ggLog'),
            ),
          ).thenThrow(Exception('ts boom'));

          final localRunner = CommandRunner<void>('test', 'test');
          localRunner.addCommand(
            Analyze(ggLog: messages.add, typeScriptAnalyzer: mockAnalyzer),
          );

          try {
            await expectLater(
              () => localRunner.run(['analyze', '--input', tsDir.path]),
              throwsA(
                isA<Exception>().having(
                  (e) => rmControls(e.toString()),
                  'message',
                  contains('ts boom'),
                ),
              ),
            );
          } finally {
            tsDir.deleteSync(recursive: true);
          }
        });
      });

      // .......................................................................
      group('should succeed', () {
        test('skipping when the project has no manifest', () async {
          final emptyDir = Directory.systemTemp.createTempSync();
          final dartAnalyzer = MockAnalyzer();
          final tsAnalyzer = MockAnalyzer();

          final localRunner = CommandRunner<void>('test', 'test');
          localRunner.addCommand(
            Analyze(
              ggLog: messages.add,
              dartAnalyzer: dartAnalyzer,
              typeScriptAnalyzer: tsAnalyzer,
            ),
          );

          try {
            await localRunner.run(['analyze', '--input', emptyDir.path]);
            expect(
              messages.last,
              contains('Skipping analyze (no project manifest)'),
            );
            verifyNever(
              () => dartAnalyzer.run(
                directory: any(named: 'directory'),
                ggLog: any(named: 'ggLog'),
              ),
            );
            verifyNever(
              () => tsAnalyzer.run(
                directory: any(named: 'directory'),
                ggLog: any(named: 'ggLog'),
              ),
            );
          } finally {
            emptyDir.deleteSync(recursive: true);
          }
        });

        test('when the injected analyzer returns without throwing', () async {
          final mockAnalyzer = MockAnalyzer();
          when(
            () => mockAnalyzer.run(
              directory: any(named: 'directory'),
              ggLog: any(named: 'ggLog'),
            ),
          ).thenAnswer((_) async {});

          final localRunner = CommandRunner<void>('test', 'test');
          localRunner.addCommand(
            Analyze(ggLog: messages.add, dartAnalyzer: mockAnalyzer),
          );

          await localRunner.run(['analyze', '--input', tmpDir.path]);

          verify(
            () => mockAnalyzer.run(
              directory: any(named: 'directory'),
              ggLog: any(named: 'ggLog'),
            ),
          ).called(1);
        });

        test('dispatches bridge repos to the typescript analyzer', () async {
          // A bridge repo ships pubspec.yaml AND package.json + tsconfig.json.
          final bridgeDir = Directory.systemTemp.createTempSync();
          File('${bridgeDir.path}/pubspec.yaml').writeAsStringSync('name: b\n');
          File('${bridgeDir.path}/package.json').writeAsStringSync('{}');
          File('${bridgeDir.path}/tsconfig.json').writeAsStringSync('{}');

          final dartAnalyzer = MockAnalyzer();
          final tsAnalyzer = MockAnalyzer();
          when(
            () => tsAnalyzer.run(
              directory: any(named: 'directory'),
              ggLog: any(named: 'ggLog'),
            ),
          ).thenAnswer((_) async {});

          final localRunner = CommandRunner<void>('test', 'test');
          localRunner.addCommand(
            Analyze(
              ggLog: messages.add,
              dartAnalyzer: dartAnalyzer,
              typeScriptAnalyzer: tsAnalyzer,
            ),
          );

          try {
            await localRunner.run(['analyze', '--input', bridgeDir.path]);
            verify(
              () => tsAnalyzer.run(
                directory: any(named: 'directory'),
                ggLog: any(named: 'ggLog'),
              ),
            ).called(1);
            verifyNever(
              () => dartAnalyzer.run(
                directory: any(named: 'directory'),
                ggLog: any(named: 'ggLog'),
              ),
            );
          } finally {
            bridgeDir.deleteSync(recursive: true);
          }
        });

        test('dispatches Flutter projects to the dart analyzer', () async {
          final flutterDir = Directory.systemTemp.createTempSync();
          File('${flutterDir.path}/pubspec.yaml').writeAsStringSync(
            'name: foo\nflutter:\n  uses-material-design: true\n',
          );
          final mockAnalyzer = MockAnalyzer();
          when(
            () => mockAnalyzer.run(
              directory: any(named: 'directory'),
              ggLog: any(named: 'ggLog'),
            ),
          ).thenAnswer((_) async {});

          final localRunner = CommandRunner<void>('test', 'test');
          localRunner.addCommand(
            Analyze(ggLog: messages.add, dartAnalyzer: mockAnalyzer),
          );

          try {
            await localRunner.run(['analyze', '--input', flutterDir.path]);
            verify(
              () => mockAnalyzer.run(
                directory: any(named: 'directory'),
                ggLog: any(named: 'ggLog'),
              ),
            ).called(1);
          } finally {
            flutterDir.deleteSync(recursive: true);
          }
        });
      });
    });
  });
}
