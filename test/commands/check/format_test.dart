// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gg_capture_print/gg_capture_print.dart';
import 'package:gg_is_github/gg_is_github.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart';
import 'package:test/test.dart';

void main() {
  final messages = <String>[];

  // Strip the colors so the expectations stay readable. One closure
  // instance, not a function declaration: mocktail matches the ggLog
  // argument by identity, and a tear-off is not stable.
  // ignore: prefer_function_declarations_over_variables
  final GgLog ggLog = (String msg) => messages.add(rmControls(msg));
  late CommandRunner<void> runner;
  late Directory tmpDir;

  setUpAll(() {
    registerFallbackValue(Directory(''));
  });

  // ...........................................................................
  setUp(() {
    testIsGitHub = false;
    messages.clear();
    runner = CommandRunner<void>('test', 'test');
    runner.addCommand(Format(ggLog: ggLog));
    tmpDir = Directory.systemTemp.createTempSync();
    // A valid pubspec.yaml makes `detectProjectType` return ProjectType.dart.
    File('${tmpDir.path}/pubspec.yaml').writeAsStringSync('name: foo\n');
  });

  // ...........................................................................
  tearDown(() {
    tmpDir.deleteSync(recursive: true);
    testIsGitHub = null;
  });

  // ...........................................................................
  Future<void> createSampleFiles() async {
    final file = File(join(tmpDir.path, 'test.dart'));
    file.writeAsStringSync(fooWithFormattingError);

    final subDir = Directory(join(tmpDir.path, 'sub'));
    await subDir.create();
    final file1 = File(join(subDir.path, 'test1.dart'));
    file1.writeAsStringSync(fooWithFormattingError);
  }

  group('Format', () {
    group('run()', () {
      group('should print a usage description', () {
        test('when called with args=[--help]', () async {
          await capturePrint(
            ggLog: ggLog,
            code: () => runner.run(['format', '--help']),
          );
          expect(messages.last, contains('Runs the project formatter.'));
        });
      });

      group('should throw', () {
        test('if input is missing', () async {
          await expectLater(
            runner.run(['format', '--input=some-unknown-dir']),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.message,
                'message',
                contains('Directory "some-unknown-dir" does not exist.'),
              ),
            ),
          );
        });

        test('when the injected typescript formatter throws', () async {
          final tsDir = Directory.systemTemp.createTempSync();
          File('${tsDir.path}/package.json').writeAsStringSync('{}');
          File('${tsDir.path}/tsconfig.json').writeAsStringSync('{}');
          final mockFormatter = MockFormatter();
          when(
            () => mockFormatter.run(
              directory: any(named: 'directory'),
              ggLog: any(named: 'ggLog'),
            ),
          ).thenThrow(Exception('ts boom'));

          final localRunner = CommandRunner<void>('test', 'test');
          localRunner.addCommand(
            Format(ggLog: ggLog, typeScriptFormatter: mockFormatter),
          );

          try {
            await expectLater(
              () => localRunner.run(['format', '--input', tsDir.path]),
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

        test('when the injected formatter throws', () async {
          final mockFormatter = MockFormatter();
          when(
            () => mockFormatter.run(
              directory: any(named: 'directory'),
              ggLog: any(named: 'ggLog'),
            ),
          ).thenThrow(Exception('boom'));

          final localRunner = CommandRunner<void>('test', 'test');
          localRunner.addCommand(
            Format(ggLog: ggLog, dartFormatter: mockFormatter),
          );

          await expectLater(
            () => localRunner.run(['format', '--input', tmpDir.path]),
            throwsA(
              isA<Exception>().having(
                (e) => rmControls(e.toString()),
                'message',
                contains('boom'),
              ),
            ),
          );
        });
      });

      // .......................................................................
      // Integration tests against the real `dart format` binary.
      group('should skip', () {
        test('when the project has no manifest', () async {
          final emptyDir = Directory.systemTemp.createTempSync();
          try {
            await runner.run(['format', '--input', emptyDir.path]);
            expect(
              messages.last,
              contains('Skipping format (no project manifest)'),
            );
          } finally {
            emptyDir.deleteSync(recursive: true);
          }
        });
      });

      group('dart formatter integration', () {
        test('fails on GitHub when files need formatting', () async {
          testIsGitHub = true;
          await createSampleFiles();

          await expectLater(
            () => runner.run(['format', '--input', tmpDir.path]),
            throwsA(
              isA<Exception>().having(
                (e) => rmControls(e.toString()),
                'message',
                contains('Exception: dart format failed.'),
              ),
            ),
          );

          expect(messages[0], contains('⌛️ Running "dart format"'));
          expect(messages[1], contains('✗ Running "dart format"'));
        });

        test('succeeds locally and rewrites files in place', () async {
          testIsGitHub = false;
          await createSampleFiles();

          await runner.run(['format', '--input', tmpDir.path]);

          expect(messages[0], contains('⌛️ Running "dart format"'));
          expect(messages[1], contains('✓ Running "dart format"'));
        });

        test('succeeds when there is nothing to format', () async {
          await runner.run(['format', '--input', tmpDir.path]);
          expect(messages[0], contains('⌛️ Running "dart format"'));
          expect(messages[1], contains('✓ Running "dart format"'));
        });
      });

      group('should dispatch', () {
        test('Flutter projects to the dart formatter', () async {
          final flutterDir = Directory.systemTemp.createTempSync();
          File('${flutterDir.path}/pubspec.yaml').writeAsStringSync(
            'name: foo\nflutter:\n  uses-material-design: true\n',
          );
          final mockFormatter = MockFormatter();
          when(
            () => mockFormatter.run(
              directory: any(named: 'directory'),
              ggLog: any(named: 'ggLog'),
            ),
          ).thenAnswer((_) async {});

          final localRunner = CommandRunner<void>('test', 'test');
          localRunner.addCommand(
            Format(ggLog: ggLog, dartFormatter: mockFormatter),
          );

          try {
            await localRunner.run(['format', '--input', flutterDir.path]);
            verify(
              () => mockFormatter.run(
                directory: any(named: 'directory'),
                ggLog: any(named: 'ggLog'),
              ),
            ).called(1);
          } finally {
            flutterDir.deleteSync(recursive: true);
          }
        });

        test('bridge repos to the typescript formatter', () async {
          // A bridge repo ships pubspec.yaml AND package.json + tsconfig.json.
          final bridgeDir = Directory.systemTemp.createTempSync();
          File('${bridgeDir.path}/pubspec.yaml').writeAsStringSync('name: b\n');
          File('${bridgeDir.path}/package.json').writeAsStringSync('{}');
          File('${bridgeDir.path}/tsconfig.json').writeAsStringSync('{}');

          final dartFormatter = MockFormatter();
          final tsFormatter = MockFormatter();
          when(
            () => tsFormatter.run(
              directory: any(named: 'directory'),
              ggLog: any(named: 'ggLog'),
            ),
          ).thenAnswer((_) async {});

          final localRunner = CommandRunner<void>('test', 'test');
          localRunner.addCommand(
            Format(
              ggLog: ggLog,
              dartFormatter: dartFormatter,
              typeScriptFormatter: tsFormatter,
            ),
          );

          try {
            await localRunner.run(['format', '--input', bridgeDir.path]);
            verify(
              () => tsFormatter.run(
                directory: any(named: 'directory'),
                ggLog: any(named: 'ggLog'),
              ),
            ).called(1);
            verifyNever(
              () => dartFormatter.run(
                directory: any(named: 'directory'),
                ggLog: any(named: 'ggLog'),
              ),
            );
          } finally {
            bridgeDir.deleteSync(recursive: true);
          }
        });
      });
    });
  });
}

// .............................................................................
const fooWithFormattingError = '''
  void foo() {
  print('Hello, World!');
}
''';
