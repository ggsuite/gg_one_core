// @license
// Copyright (c) 2019 - 2024 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gg_lang/gg_lang.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_publish/gg_publish.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart';
import 'package:test/test.dart';

class _FakeDirectory extends Fake implements Directory {}

void main() {
  final messages = <String>[];

  // Strip the colors so the expectations stay readable. One closure
  // instance, not a function declaration: mocktail matches the ggLog
  // argument by identity, and a tear-off is not stable.
  // ignore: prefer_function_declarations_over_variables
  final GgLog ggLog = (String msg) => messages.add(rmControls(msg));
  late GgProcessWrapper processWrapper;
  late PublishTo publishTo;
  late NpmLoggedIn npmLoggedIn;
  late CommandRunner<void> runner;
  late Directory d;

  setUpAll(() {
    registerFallbackValue(_FakeDirectory());
  });

  // Writes package.json with [content] plus a pnpm-lock.yaml so pnpm is the
  // detected package manager.
  void writePackageJson(String content) {
    File(join(d.path, 'package.json')).writeAsStringSync(content);
    File(join(d.path, 'pnpm-lock.yaml')).writeAsStringSync('');
  }

  // Forces the publish targets (bypasses reading pubspec/package.json), so the
  // registry-resolution path runs under our control.
  void stubTargets(Set<PublishTarget> targets) {
    when(() => publishTo.targets(any())).thenAnswer((_) async => targets);
  }

  void stubConfig(String key, {String? value, int exitCode = 0}) {
    when(
      () => processWrapper.run(
        'pnpm',
        ['config', 'get', key],
        workingDirectory: d.path,
        runInShell: true,
      ),
    ).thenAnswer((_) async => ProcessResult(0, exitCode, value ?? '', ''));
  }

  void stubWhoami({
    String? registry,
    required int exitCode,
    String stdout = '',
    String stderr = '',
  }) {
    when(
      () => processWrapper.run(
        'pnpm',
        <String>['whoami', if (registry != null) '--registry=$registry'],
        workingDirectory: d.path,
        runInShell: true,
      ),
    ).thenAnswer((_) async => ProcessResult(0, exitCode, stdout, stderr));
  }

  Future<void> run() => runner.run(['npm-logged-in', '--input', d.path]);

  setUp(() {
    messages.clear();
    processWrapper = MockGgProcessWrapper();
    publishTo = MockPublishTo();
    npmLoggedIn = NpmLoggedIn(
      ggLog: ggLog,
      processWrapper: processWrapper,
      publishTo: publishTo,
    );
    runner = CommandRunner<void>('test', 'test')..addCommand(npmLoggedIn);
    d = Directory.systemTemp.createTempSync('npm_logged_in_test');
  });

  tearDown(() {
    d.deleteSync(recursive: true);
  });

  group('NpmLoggedIn', () {
    group('skips (no npm authentication needed)', () {
      test('for a pub.dev target', () async {
        stubTargets({PublishTarget.pubDev});
        await run();
        expect(messages.single, contains('✓ Skipping npm auth check'));
        expect(messages.single, contains('pub.dev'));
      });

      test('for a none (private) target', () async {
        stubTargets(<PublishTarget>{});
        await run();
        expect(messages.single, contains('✓ Skipping npm auth check'));
        expect(messages.single, contains('none'));
      });
    });

    group('resolves the target registry', () {
      test('from publishConfig.registry in package.json', () async {
        stubTargets({PublishTarget.npm});
        writePackageJson(
          '{"name": "@org/x", "publishConfig": '
          '{"registry": "https://pkgs.dev.azure.com/feed/"}}',
        );
        stubWhoami(
          registry: 'https://pkgs.dev.azure.com/feed/',
          exitCode: 0,
          stdout: 'user',
        );
        await run();
        expect(
          messages.any(
            (m) =>
                m.contains('✓ Logged in to https://pkgs.dev.azure.com/feed/'),
          ),
          isTrue,
        );
        verify(
          () => processWrapper.run(
            'pnpm',
            ['whoami', '--registry=https://pkgs.dev.azure.com/feed/'],
            workingDirectory: d.path,
            runInShell: true,
          ),
        ).called(1);
      });

      test('from the scope registry (@scope:registry)', () async {
        stubTargets({PublishTarget.npm});
        writePackageJson('{"name": "@org/x"}');
        stubConfig('@org:registry', value: 'https://scoped.example/');
        stubWhoami(
          registry: 'https://scoped.example/',
          exitCode: 0,
          stdout: 'u',
        );
        await run();
        expect(
          messages.any(
            (m) => m.contains('✓ Logged in to https://scoped.example/'),
          ),
          isTrue,
        );
      });

      test(
        'falls back to the default registry when the scope has none',
        () async {
          stubTargets({PublishTarget.npm});
          writePackageJson('{"name": "@org/x"}');
          stubConfig('@org:registry', value: 'undefined');
          stubConfig('registry', value: 'https://registry.npmjs.org/');
          stubWhoami(
            registry: 'https://registry.npmjs.org/',
            exitCode: 0,
            stdout: 'u',
          );
          await run();
          expect(
            messages.any(
              (m) => m.contains('✓ Logged in to https://registry.npmjs.org/'),
            ),
            isTrue,
          );
        },
      );

      test('uses the default registry for an unscoped package', () async {
        stubTargets({PublishTarget.npm});
        writePackageJson('{"name": "x"}');
        stubConfig('registry', value: 'https://registry.npmjs.org/');
        stubWhoami(
          registry: 'https://registry.npmjs.org/',
          exitCode: 0,
          stdout: 'u',
        );
        await run();
        expect(
          messages.any(
            (m) => m.contains('✓ Logged in to https://registry.npmjs.org/'),
          ),
          isTrue,
        );
      });

      test('runs a bare whoami when no registry is configured', () async {
        stubTargets({PublishTarget.npm});
        writePackageJson('{"name": "x"}');
        stubConfig('registry', value: 'undefined');
        stubWhoami(registry: null, exitCode: 0, stdout: 'u');
        await run();
        expect(
          messages.any((m) => m.contains('✓ Logged in to the npm registry')),
          isTrue,
        );
        verify(
          () => processWrapper.run(
            'pnpm',
            const ['whoami'],
            workingDirectory: d.path,
            runInShell: true,
          ),
        ).called(1);
      });

      test('treats a failing config lookup as no registry', () async {
        stubTargets({PublishTarget.npm});
        writePackageJson('{"name": "x"}');
        stubConfig('registry', exitCode: 1);
        stubWhoami(registry: null, exitCode: 0, stdout: 'u');
        await run();
        expect(
          messages.any((m) => m.contains('✓ Logged in to the npm registry')),
          isTrue,
        );
      });
    });

    group('tolerates a package.json it cannot read', () {
      // The target is forced via the injected PublishTo, so registry
      // resolution still runs even when package.json is missing/unparseable.
      test('when package.json is absent', () async {
        stubTargets({PublishTarget.npm});
        File(join(d.path, 'pnpm-lock.yaml')).writeAsStringSync('');
        stubConfig('registry', value: 'https://registry.npmjs.org/');
        stubWhoami(
          registry: 'https://registry.npmjs.org/',
          exitCode: 0,
          stdout: 'u',
        );
        await run();
        expect(messages.any((m) => m.contains('✓ Logged in')), isTrue);
      });

      test('when package.json is malformed', () async {
        stubTargets({PublishTarget.npm});
        writePackageJson('not json');
        stubConfig('registry', value: 'https://registry.npmjs.org/');
        stubWhoami(
          registry: 'https://registry.npmjs.org/',
          exitCode: 0,
          stdout: 'u',
        );
        await run();
        expect(messages.any((m) => m.contains('✓ Logged in')), isTrue);
      });

      test('when package.json is not a JSON object', () async {
        stubTargets({PublishTarget.npm});
        writePackageJson('[1, 2, 3]');
        stubConfig('registry', value: 'https://registry.npmjs.org/');
        stubWhoami(
          registry: 'https://registry.npmjs.org/',
          exitCode: 0,
          stdout: 'u',
        );
        await run();
        expect(messages.any((m) => m.contains('✓ Logged in')), isTrue);
      });

      test('when publishConfig has no registry field', () async {
        stubTargets({PublishTarget.npm});
        writePackageJson('{"name": "x", "publishConfig": {}}');
        stubConfig('registry', value: 'https://registry.npmjs.org/');
        stubWhoami(
          registry: 'https://registry.npmjs.org/',
          exitCode: 0,
          stdout: 'u',
        );
        await run();
        expect(messages.any((m) => m.contains('✓ Logged in')), isTrue);
      });
    });

    group('auth outcomes', () {
      test(
        'throws for a clear auth failure (401), naming the registry',
        () async {
          stubTargets({PublishTarget.npm});
          writePackageJson('{"name": "x"}');
          stubConfig('registry', value: 'https://registry.npmjs.org/');
          stubWhoami(
            registry: 'https://registry.npmjs.org/',
            exitCode: 1,
            stderr: '401 Unauthorized',
          );
          await expectLater(
            run(),
            throwsA(
              isA<Exception>().having(
                (e) => rmControls(e.toString()),
                'message',
                allOf(
                  contains('Not logged in to https://registry.npmjs.org/'),
                  contains('401 Unauthorized'),
                  contains('pnpm login --registry=https://registry.npmjs.org/'),
                ),
              ),
            ),
          );
          expect(messages.any((m) => m.contains('✗ Logged in')), isTrue);
        },
      );

      test(
        'skips (no false-fail) when the registry does not support whoami',
        () async {
          stubTargets({PublishTarget.npm});
          writePackageJson('{"name": "x"}');
          stubConfig('registry', value: 'https://pkgs.dev.azure.com/feed/');
          stubWhoami(
            registry: 'https://pkgs.dev.azure.com/feed/',
            exitCode: 1,
            stdout: 'Unknown command: whoami',
          );
          await run();
          expect(messages.any((m) => m.contains('✓ Logged in')), isTrue);
        },
      );
    });

    test('example provides a real instance', () {
      expect(NpmLoggedIn.example(), isA<NpmLoggedIn>());
    });
  });
}
