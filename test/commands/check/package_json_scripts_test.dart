// @license
// Copyright (c) 2019 - 2024 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
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

  setUp(() {
    messages.clear();
    runner = CommandRunner<void>('test', 'test');
    runner.addCommand(CheckPackageJsonScripts(ggLog: ggLog));
    tmpDir = Directory.systemTemp.createTempSync();
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  const validScripts = <String, String>{
    'test': 'vitest run && npm run lint',
    'build': 'npm run test && tsc',
    'lint': 'eslint',
    'prepublish': 'npm run build',
  };

  // Writes a TypeScript project (package.json + tsconfig.json) declaring the
  // given [scripts]. When [private] is true, the package.json sets
  // `"private": true`.
  void writeTsProject(Map<String, String> scripts, {bool private = false}) {
    final entries = scripts.entries
        .map((e) => '"${e.key}": "${e.value}"')
        .join(', ');
    final privateField = private ? '"private": true, ' : '';
    File(
      '${tmpDir.path}/package.json',
    ).writeAsStringSync('{"name": "ts", $privateField"scripts": {$entries}}');
    File('${tmpDir.path}/tsconfig.json').writeAsStringSync('{}');
  }

  // Writes a hybrid that ships no TypeScript sources: a Dart package whose
  // package.json exists to publish a payload to npm. No tsconfig.json.
  void writeHybridWithoutTypeScript(Map<String, String> scripts) {
    final entries = scripts.entries
        .map((e) => '"${e.key}": "${e.value}"')
        .join(', ');
    File('${tmpDir.path}/pubspec.yaml').writeAsStringSync('name: foo\n');
    File(
      '${tmpDir.path}/package.json',
    ).writeAsStringSync('{"name": "foo", "scripts": {$entries}}');
  }

  Future<void> run() =>
      runner.run(['package-json-scripts', '--input', tmpDir.path]);

  group('CheckPackageJsonScripts', () {
    group('skips', () {
      test('a Dart project', () async {
        File('${tmpDir.path}/pubspec.yaml').writeAsStringSync('name: foo\n');
        await run();
        expect(messages, isEmpty);
      });

      test('a directory without a recognizable manifest', () async {
        await run();
        expect(messages, isEmpty);
      });
    });

    group('succeeds', () {
      test('when all required scripts are present, build runs test and '
          'prepublish runs build', () async {
        writeTsProject(validScripts);
        await run();
        expect(messages.any((m) => m.contains('✓')), isTrue);
      });

      test('for a bridge whose build does not run test (exempt)', () async {
        // A bridge (pubspec.yaml + package.json + tsconfig.json) is exempt from
        // the build -> test rule; its build produces the Dart+TS artifacts and
        // tests separately. prepublishOnly -> build still applies.
        final scripts = Map<String, String>.from(validScripts)
          ..['build'] = 'tsc';
        writeTsProject(scripts);
        File('${tmpDir.path}/pubspec.yaml').writeAsStringSync('name: b\n');
        await run();
        expect(messages.any((m) => m.contains('✓')), isTrue);
      });

      test('when not build but prebuild runs test', () async {
        // npm runs `prebuild` right before `build`, so the tests still run as
        // part of a build.
        final scripts = Map<String, String>.from(validScripts)
          ..['build'] = 'tsc'
          ..['prebuild'] = 'npm run test';
        writeTsProject(scripts);
        await run();
        expect(messages.any((m) => m.contains('✓')), isTrue);
      });

      test('when the publish-lifecycle script is prepublishOnly '
          '(npm\'s modern name)', () async {
        final scripts = Map<String, String>.from(validScripts)
          ..remove('prepublish')
          ..['prepublishOnly'] = 'npm run build';
        writeTsProject(scripts);
        await run();
        expect(messages.any((m) => m.contains('✓')), isTrue);
      });

      test('for a private package without a prepublish script', () async {
        // Private packages are never published, so no prepublish script is
        // required — but the build -> test rule still applies.
        final scripts = Map<String, String>.from(validScripts)
          ..remove('prepublish');
        writeTsProject(scripts, private: true);
        await run();
        expect(messages.any((m) => m.contains('✓')), isTrue);
      });
    });

    group('throws', () {
      test('when a required script is missing', () async {
        final scripts = Map<String, String>.from(validScripts)..remove('build');
        writeTsProject(scripts);
        await expectLater(
          run(),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              allOf(contains('missing required scripts'), contains('build')),
            ),
          ),
        );
      });

      test('when neither prepublish nor prepublishOnly is present', () async {
        final scripts = Map<String, String>.from(validScripts)
          ..remove('prepublish');
        writeTsProject(scripts);
        await expectLater(
          run(),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              allOf(contains('publish-lifecycle'), contains('prepublishOnly')),
            ),
          ),
        );
      });

      test('when the build script does not run test', () async {
        final scripts = Map<String, String>.from(validScripts)
          ..['build'] = 'tsc';
        writeTsProject(scripts);
        await expectLater(
          run(),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              allOf(contains('"build" script'), contains('test')),
            ),
          ),
        );
      });

      test('when neither build nor prebuild runs test', () async {
        final scripts = Map<String, String>.from(validScripts)
          ..['build'] = 'tsc'
          ..['prebuild'] = 'rimraf dist';
        writeTsProject(scripts);
        await expectLater(
          run(),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              allOf(contains('"build" script'), contains('prebuild')),
            ),
          ),
        );
      });

      test('when the build script does not run test, even for a private '
          'package', () async {
        // The build -> test rule applies to private packages too.
        final scripts = Map<String, String>.from(validScripts)
          ..remove('prepublish')
          ..['build'] = 'tsc';
        writeTsProject(scripts, private: true);
        await expectLater(
          run(),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              allOf(contains('"build" script'), contains('test')),
            ),
          ),
        );
      });

      test('when the prepublish script does not run build', () async {
        final scripts = Map<String, String>.from(validScripts)
          ..['prepublish'] = 'npm run test';
        writeTsProject(scripts);
        await expectLater(
          run(),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              allOf(contains('prepublish'), contains('build')),
            ),
          ),
        );
      });
    });

    group('a hybrid without TypeScript', () {
      test('needs neither build nor lint', () async {
        writeHybridWithoutTypeScript({
          'test': 'dart test',
          'prepublishOnly': 'pnpm run test',
        });
        await run();
        expect(messages.any((m) => m.contains('✓')), isTrue);
      });

      test('still needs test', () async {
        writeHybridWithoutTypeScript({'prepublishOnly': 'pnpm run test'});
        await expectLater(
          run,
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              allOf(
                contains('missing required scripts: test'),
                // build and lint are not demanded of it.
                isNot(contains('build')),
                isNot(contains('lint')),
              ),
            ),
          ),
        );
      });

      test('its publish-lifecycle script must reach test, not build', () async {
        writeHybridWithoutTypeScript({
          'test': 'dart test',
          'prepublishOnly': 'echo nothing',
        });
        await expectLater(
          run,
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              contains('"prepublishOnly" script must run test'),
            ),
          ),
        );
      });

      test('needs a publish-lifecycle script at all', () async {
        writeHybridWithoutTypeScript({'test': 'dart test'});
        await expectLater(
          run,
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              allOf(
                contains('missing a publish-lifecycle script'),
                contains('it must run test'),
              ),
            ),
          ),
        );
      });
    });

    test('example provides a real instance', () {
      expect(CheckPackageJsonScripts.example(), isA<CheckPackageJsonScripts>());
    });
  });
}
