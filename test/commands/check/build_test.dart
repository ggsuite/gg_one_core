// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one_core/gg_one_core.dart';
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
  late GgProcessWrapper processWrapper;
  late Build build;
  late CommandRunner<void> runner;
  late Directory d;

  // Writes a bridge project (pubspec.yaml + package.json + tsconfig.json)
  // declaring the given [scripts]. A `pnpm-lock.yaml` is added when [pnpm].
  void writeBridge({Map<String, String>? scripts, bool pnpm = false}) {
    File('${d.path}/pubspec.yaml').writeAsStringSync('name: b\n');
    File('${d.path}/tsconfig.json').writeAsStringSync('{}');
    final s = scripts ?? const {'build': 'tsc'};
    final entries = s.entries.map((e) => '"${e.key}":"${e.value}"').join(',');
    File('${d.path}/package.json')
        .writeAsStringSync('{"name":"b","scripts":{$entries}}');
    if (pnpm) {
      File('${d.path}/pnpm-lock.yaml').writeAsStringSync('');
    }
  }

  void mockRun(ProcessResult result) {
    when(
      () => processWrapper.run(
        any(),
        any(),
        workingDirectory: any(named: 'workingDirectory'),
        runInShell: any(named: 'runInShell'),
      ),
    ).thenAnswer((_) async => result);
  }

  setUp(() {
    messages.clear();
    processWrapper = MockGgProcessWrapper();
    build = Build(ggLog: ggLog, processWrapper: processWrapper);
    runner = CommandRunner<void>('test', 'test')..addCommand(build);
    d = Directory.systemTemp.createTempSync('gg_build_test');
  });

  tearDown(() {
    d.deleteSync(recursive: true);
  });

  Future<void> run() => runner.run(['build', '--input', d.path]);

  group('Build', () {
    test('skips a non-bridge (Dart) project', () async {
      File('${d.path}/pubspec.yaml').writeAsStringSync('name: a\n');
      await run();
      expect(messages, isEmpty);
      verifyNever(
        () => processWrapper.run(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      );
    });

    test('skips a bridge without a build script', () async {
      writeBridge(scripts: const {'test': 'vitest run'});
      await run();
      expect(messages, isEmpty);
      verifyNever(
        () => processWrapper.run(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      );
    });

    test('runs "npm run build" for a bridge (npm by default)', () async {
      writeBridge();
      mockRun(ProcessResult(0, 0, '', ''));
      await run();
      expect(messages.any((m) => m.contains('✓')), isTrue);

      final captured = verify(
        () => processWrapper.run(
          captureAny(),
          captureAny(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: captureAny(named: 'runInShell'),
        ),
      ).captured;
      expect(captured[0], 'npm');
      expect(captured[1], ['run', 'build']);
      expect(captured[2], isTrue);
    });

    test('uses pnpm when a pnpm-lock.yaml is present', () async {
      writeBridge(pnpm: true);
      mockRun(ProcessResult(0, 0, '', ''));
      await run();

      final captured = verify(
        () => processWrapper.run(
          captureAny(),
          captureAny(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).captured;
      expect(captured[0], 'pnpm');
      expect(captured[1], ['run', 'build']);
    });

    test('throws and logs output when the build fails', () async {
      writeBridge();
      mockRun(ProcessResult(0, 1, 'build stdout', 'build stderr'));
      await expectLater(
        run(),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            allOf(contains('npm run build'), contains('exit code 1')),
          ),
        ),
      );
      expect(messages.any((m) => m.contains('build stdout')), isTrue);
      expect(messages.any((m) => m.contains('build stderr')), isTrue);
    });

    test('example provides a real instance', () {
      expect(Build.example(), isA<Build>());
    });
  });
}
