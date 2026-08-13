// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_lang/gg_lang.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one_core/src/tools/analyzer.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

void main() {
  final messages = <String>[];

  // Strip the colors so the expectations stay readable. One closure
  // instance, not a function declaration: mocktail matches the ggLog
  // argument by identity, and a tear-off is not stable.
  // ignore: prefer_function_declarations_over_variables
  final GgLog ggLog = (String msg) => messages.add(rmControls(msg));
  late Directory tmpDir;
  late MockGgProcessWrapper processWrapper;

  setUp(() {
    messages.clear();
    tmpDir = Directory.systemTemp.createTempSync();
    processWrapper = MockGgProcessWrapper();
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  group('DartAnalyzer', () {
    test('runs "dart analyze --fatal-infos --fatal-warnings" and succeeds '
        'when exit code is 0', () async {
      when(
        () => processWrapper.run(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

      final analyzer = DartAnalyzer(processWrapper: processWrapper);
      await analyzer.run(directory: tmpDir, ggLog: ggLog);

      final captured = verify(
        () => processWrapper.run(
          captureAny(),
          captureAny(),
          workingDirectory: captureAny(named: 'workingDirectory'),
        ),
      ).captured;
      expect(captured[0], 'dart');
      expect(captured[1], ['analyze', '--fatal-infos', '--fatal-warnings']);
      expect(captured[2], tmpDir.path);

      expect(messages[0], contains('⌛️ Running "dart analyze"'));
      expect(messages[1], contains('✓ Running "dart analyze"'));
    });

    test(
      'throws and logs offending files when exit code is non-zero',
      () async {
        when(
          () => processWrapper.run(
            any(),
            any(),
            workingDirectory: any(named: 'workingDirectory'),
            runInShell: any(named: 'runInShell'),
          ),
        ).thenAnswer(
          (_) async => ProcessResult(1, 1, 'lib/foo.dart:10:3 • issue', ''),
        );

        final analyzer = DartAnalyzer(processWrapper: processWrapper);
        await expectLater(
          () => analyzer.run(directory: tmpDir, ggLog: ggLog),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              contains('Run "dart analyze"'),
            ),
          ),
        );

        expect(messages, contains('There are analyzer errors:'));
      },
    );

    test('defaults processWrapper when not provided', () {
      const analyzer = DartAnalyzer();
      expect(analyzer.processWrapper, isA<GgProcessWrapper>());
    });
  });

  group('TypeScriptAnalyzer', () {
    test('runs tsc --noEmit via the detected package manager', () async {
      File('${tmpDir.path}/tsconfig.json').writeAsStringSync('{}');
      when(
        () => processWrapper.run(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

      final analyzer = TypeScriptAnalyzer(
        processWrapper: processWrapper,
        packageManager: (_) => TypeScriptPackageManager.pnpm,
      );
      await analyzer.run(directory: tmpDir, ggLog: ggLog);

      final captured = verify(
        () => processWrapper.run(
          captureAny(),
          captureAny(),
          workingDirectory: captureAny(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).captured;
      expect(captured[0], 'pnpm');
      expect(captured[1], ['exec', 'tsc', '--noEmit']);
      expect(captured[2], tmpDir.path);
      expect(messages[0], contains('⌛️ Running "tsc --noEmit"'));
      expect(messages[1], contains('✓ Running "tsc --noEmit"'));
    });

    test('runs the package.json "lint" script when one is defined', () async {
      File('${tmpDir.path}/package.json')
          .writeAsStringSync('{"scripts":{"lint":"eslint"}}');
      when(
        () => processWrapper.run(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

      final analyzer = TypeScriptAnalyzer(
        processWrapper: processWrapper,
        packageManager: (_) => TypeScriptPackageManager.pnpm,
      );
      await analyzer.run(directory: tmpDir, ggLog: ggLog);

      final captured = verify(
        () => processWrapper.run(
          captureAny(),
          captureAny(),
          workingDirectory: captureAny(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).captured;
      expect(captured[0], 'pnpm');
      expect(captured[1], ['run', 'lint']);
      expect(captured[2], tmpDir.path);
      expect(messages[0], contains('⌛️ Running "pnpm run lint"'));
      expect(messages[1], contains('✓ Running "pnpm run lint"'));
    });

    test('skips when there is no lint script and no tsconfig', () async {
      // A hybrid whose package.json only publishes a payload ships no
      // TypeScript sources. Falling back to `tsc` would demand a compiler
      // the project has no reason to depend on.
      final analyzer = TypeScriptAnalyzer(
        processWrapper: processWrapper,
        packageManager: (_) => TypeScriptPackageManager.pnpm,
      );
      await analyzer.run(directory: tmpDir, ggLog: ggLog);

      verifyNever(
        () => processWrapper.run(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      );
      expect(messages.single, contains('Skipping TypeScript analysis'));
    });

    test('throws and echoes tool output on failure', () async {
      File('${tmpDir.path}/tsconfig.json').writeAsStringSync('{}');
      when(
        () => processWrapper.run(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer(
        (_) async => ProcessResult(1, 1, 'src/foo.ts(3,1): error TS2322', ''),
      );

      final analyzer = TypeScriptAnalyzer(
        processWrapper: processWrapper,
        packageManager: (_) => TypeScriptPackageManager.npm,
      );

      await expectLater(
        () => analyzer.run(directory: tmpDir, ggLog: ggLog),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('TypeScript analysis failed'),
          ),
        ),
      );
      expect(messages, contains('src/foo.ts(3,1): error TS2322'));
    });

    test('detects the package manager from the directory by default', () async {
      File('${tmpDir.path}/tsconfig.json').writeAsStringSync('{}');
      File('${tmpDir.path}/yarn.lock').writeAsStringSync('');
      when(
        () => processWrapper.run(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

      final analyzer = TypeScriptAnalyzer(processWrapper: processWrapper);
      await analyzer.run(directory: tmpDir, ggLog: ggLog);

      final captured = verify(
        () => processWrapper.run(
          captureAny(),
          captureAny(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).captured;
      expect(captured[0], 'yarn');
      expect(captured[1], ['tsc', '--noEmit']);
    });

    test('defaults processWrapper when not provided', () {
      const analyzer = TypeScriptAnalyzer();
      expect(analyzer.processWrapper, isA<GgProcessWrapper>());
    });
  });

  group('examples', () {
    test('provide real, usable instances', () {
      expect(DartAnalyzer.example(), isA<DartAnalyzer>());
      expect(TypeScriptAnalyzer.example(), isA<TypeScriptAnalyzer>());
    });
  });
}
