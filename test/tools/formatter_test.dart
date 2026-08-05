// @license
// Copyright (c) 2019 - 2024 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_lang/gg_lang.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one_core/src/tools/formatter.dart';
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

  group('DartFormatter', () {
    test('runs "dart format . -o write --set-exit-if-changed"', () async {
      when(
        () => processWrapper.run(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

      final formatter = DartFormatter(
        processWrapper: processWrapper,
        isGitHub: () => false,
      );
      await formatter.run(directory: tmpDir, ggLog: ggLog);

      final captured = verify(
        () => processWrapper.run(
          captureAny(),
          captureAny(),
          workingDirectory: captureAny(named: 'workingDirectory'),
        ),
      ).captured;
      expect(captured[0], 'dart');
      expect(captured[1], [
        'format',
        '.',
        '-o',
        'write',
        '--set-exit-if-changed',
      ]);
      expect(captured[2], tmpDir.path);
      expect(messages[0], contains('⌛️ Running "dart format"'));
      expect(messages[1], contains('✓ Running "dart format"'));
    });

    test('succeeds locally when files were rewritten', () async {
      when(
        () => processWrapper.run(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer(
        (_) async => ProcessResult(1, 1, 'Formatted lib/foo.dart', ''),
      );

      final formatter = DartFormatter(
        processWrapper: processWrapper,
        isGitHub: () => false,
      );

      await formatter.run(directory: tmpDir, ggLog: ggLog);
      expect(messages[1], contains('✓'));
    });

    test('throws on GitHub when files were rewritten', () async {
      when(
        () => processWrapper.run(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer(
        (_) async => ProcessResult(1, 1, 'Formatted lib/foo.dart', ''),
      );

      final formatter = DartFormatter(
        processWrapper: processWrapper,
        isGitHub: () => true,
      );

      await expectLater(
        () => formatter.run(directory: tmpDir, ggLog: ggLog),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('dart format failed.'),
          ),
        ),
      );
    });

    test('throws when the formatter exits with error and no files', () async {
      when(
        () => processWrapper.run(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((_) async => ProcessResult(1, 2, '', 'broken stderr'));

      final formatter = DartFormatter(
        processWrapper: processWrapper,
        isGitHub: () => false,
      );

      await expectLater(
        () => formatter.run(directory: tmpDir, ggLog: ggLog),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('dart format failed.'),
          ),
        ),
      );
    });

    test('defaults to real isGitHub detection when not injected', () {
      const formatter = DartFormatter();
      expect(formatter.processWrapper, isA<GgProcessWrapper>());
    });
  });

  group('TypeScriptFormatter', () {
    test('skips formatting when no "format" script exists (local)', () async {
      File(
        '${tmpDir.path}/package.json',
      ).writeAsStringSync('{"scripts":{"lint":"eslint"}}');

      final formatter = TypeScriptFormatter(
        processWrapper: processWrapper,
        isGitHub: () => false,
        packageManager: (_) => TypeScriptPackageManager.pnpm,
      );
      await formatter.run(directory: tmpDir, ggLog: ggLog);

      // No tool is invoked — gg never calls eslint (or anything) directly.
      verifyNever(
        () => processWrapper.run(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      );
      expect(
        messages.last,
        contains('No "format" script — skipping TypeScript formatting'),
      );
    });

    test('skips formatting when no "format:check" script exists '
        '(GitHub)', () async {
      File(
        '${tmpDir.path}/package.json',
      ).writeAsStringSync('{"scripts":{"lint":"eslint"}}');

      final formatter = TypeScriptFormatter(
        processWrapper: processWrapper,
        isGitHub: () => true,
        packageManager: (_) => TypeScriptPackageManager.npm,
      );
      await formatter.run(directory: tmpDir, ggLog: ggLog);

      verifyNever(
        () => processWrapper.run(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      );
      expect(
        messages.last,
        contains('No "format:check" script — skipping TypeScript formatting'),
      );
    });

    test('throws and echoes tool output when the format script exits '
        'non-zero', () async {
      File(
        '${tmpDir.path}/package.json',
      ).writeAsStringSync('{"scripts":{"format":"prettier --write ."}}');
      when(
        () => processWrapper.run(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer(
        (_) async => ProcessResult(1, 1, 'src/foo.ts: 2 problems', 'boom'),
      );

      final formatter = TypeScriptFormatter(
        processWrapper: processWrapper,
        isGitHub: () => false,
        packageManager: (_) => TypeScriptPackageManager.pnpm,
      );

      await expectLater(
        () => formatter.run(directory: tmpDir, ggLog: ggLog),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Format check failed'),
          ),
        ),
      );
      expect(messages, contains('src/foo.ts: 2 problems'));
      expect(messages, contains('boom'));
    });

    test('runs the package.json "format" script locally', () async {
      File(
        '${tmpDir.path}/package.json',
      ).writeAsStringSync('{"scripts":{"format":"prettier --write ."}}');
      when(
        () => processWrapper.run(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

      final formatter = TypeScriptFormatter(
        processWrapper: processWrapper,
        isGitHub: () => false,
        packageManager: (_) => TypeScriptPackageManager.pnpm,
      );
      await formatter.run(directory: tmpDir, ggLog: ggLog);

      final captured = verify(
        () => processWrapper.run(
          captureAny(),
          captureAny(),
          workingDirectory: captureAny(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).captured;
      expect(captured[0], 'pnpm');
      expect(captured[1], ['run', 'format']);
      expect(messages[0], contains('⌛️ Running "pnpm run format"'));
      expect(messages[1], contains('✓ Running "pnpm run format"'));
    });

    test('runs the package.json "format:check" script on GitHub', () async {
      File(
        '${tmpDir.path}/package.json',
      ).writeAsStringSync('{"scripts":{"format:check":"prettier --check ."}}');
      when(
        () => processWrapper.run(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

      final formatter = TypeScriptFormatter(
        processWrapper: processWrapper,
        isGitHub: () => true,
        packageManager: (_) => TypeScriptPackageManager.npm,
      );
      await formatter.run(directory: tmpDir, ggLog: ggLog);

      final captured = verify(
        () => processWrapper.run(
          captureAny(),
          captureAny(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).captured;
      expect(captured[0], 'npm');
      expect(captured[1], ['run', 'format:check']);
    });

    test('detects the package manager from the directory by default', () async {
      File('${tmpDir.path}/pnpm-lock.yaml').writeAsStringSync('');
      File(
        '${tmpDir.path}/package.json',
      ).writeAsStringSync('{"scripts":{"format":"prettier --write ."}}');
      when(
        () => processWrapper.run(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

      final formatter = TypeScriptFormatter(
        processWrapper: processWrapper,
        isGitHub: () => false,
      );
      await formatter.run(directory: tmpDir, ggLog: ggLog);

      final captured = verify(
        () => processWrapper.run(
          captureAny(),
          captureAny(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).captured;
      expect(captured[0], 'pnpm');
      expect(captured[1], ['run', 'format']);
    });

    test('defaults processWrapper and isGitHub when not provided', () {
      const formatter = TypeScriptFormatter();
      expect(formatter.processWrapper, isA<GgProcessWrapper>());
    });
  });

  group('examples', () {
    test('provide real, usable instances', () {
      expect(DartFormatter.example(), isA<DartFormatter>());
      expect(TypeScriptFormatter.example(), isA<TypeScriptFormatter>());
    });
  });
}
