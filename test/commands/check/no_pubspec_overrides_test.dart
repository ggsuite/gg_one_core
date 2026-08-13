// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:path/path.dart';
import 'package:test/test.dart';

void main() {
  final messages = <String>[];

  // Strip the colors so the expectations stay readable. One closure
  // instance, not a function declaration: mocktail matches the ggLog
  // argument by identity, and a tear-off is not stable.
  // ignore: prefer_function_declarations_over_variables
  final GgLog ggLog = (String msg) => messages.add(rmControls(msg));
  late NoPubspecOverrides noPubspecOverrides;
  late CommandRunner<void> runner;
  late Directory d;

  Future<void> run() => runner.run(['no-pubspec-overrides', '--input', d.path]);

  void writePubspec() {
    File(join(d.path, 'pubspec.yaml')).writeAsStringSync('name: test\n');
  }

  void writeOverrides() {
    File(join(d.path, 'pubspec_overrides.yaml')).writeAsStringSync(
      'dependency_overrides:\n  gg_log:\n    path: ../gg_log',
    );
  }

  setUp(() {
    messages.clear();
    noPubspecOverrides = NoPubspecOverrides(ggLog: ggLog);
    runner = CommandRunner<void>('test', 'test')
      ..addCommand(noPubspecOverrides);
    d = Directory.systemTemp.createTempSync('no_pubspec_overrides_test');
  });

  tearDown(() {
    d.deleteSync(recursive: true);
  });

  group('NoPubspecOverrides', () {
    test('example instance is available', () {
      expect(NoPubspecOverrides.example(), isA<NoPubspecOverrides>());
    });

    test('succeeds when no pubspec_overrides.yaml exists', () async {
      writePubspec();
      await run();
      expect(messages.last, contains('✓ No pubspec_overrides.yaml'));
    });

    test('succeeds when the overrides only pin git refs', () async {
      writePubspec();
      File(join(d.path, 'pubspec_overrides.yaml')).writeAsStringSync(
        'dependency_overrides:\n'
        '  gg_log:\n'
        '    git:\n'
        '      url: git@github.com:user/gg_log.git\n'
        '      ref: feature123\n',
      );
      await run();
      expect(messages.last, contains('✓ No pubspec_overrides.yaml'));
    });

    test('throws when a pubspec_overrides.yaml redirects to a path', () async {
      writePubspec();
      writeOverrides();
      await expectLater(
        run(),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            allOf(
              contains('pubspec_overrides.yaml exists'),
              contains('Delete'),
            ),
          ),
        ),
      );
      expect(messages.last, contains('✗ No pubspec_overrides.yaml'));
    });

    test('skips for non Dart projects', () async {
      File(join(d.path, 'package.json')).writeAsStringSync('{"name": "x"}');
      writeOverrides();
      await run();
      expect(messages, isEmpty);
    });

    test('the mock can be used', () {
      expect(MockNoPubspecOverrides(), isA<NoPubspecOverrides>());
    });

    group('hasLocalizedRefs()', () {
      // Writes pubspec_overrides.yaml with [content] and asks the check.
      bool withOverrides(String content) {
        File(join(d.path, 'pubspec_overrides.yaml')).writeAsStringSync(content);
        return NoPubspecOverrides.hasLocalizedRefs(d);
      }

      test('is false without a pubspec_overrides.yaml', () {
        expect(NoPubspecOverrides.hasLocalizedRefs(d), isFalse);
      });

      test('is false for an empty file', () {
        expect(withOverrides('\n  \n'), isFalse);
      });

      test('is false for an empty dependency_overrides mapping', () {
        expect(withOverrides('dependency_overrides:\n'), isFalse);
        expect(withOverrides('dependency_overrides: {}\n'), isFalse);
      });

      test('is false without a dependency_overrides key', () {
        expect(withOverrides('name: test\n'), isFalse);
      });

      test('is false when the document is no mapping', () {
        expect(withOverrides('- a\n- b\n'), isFalse);
      });

      test('is false for a git override', () {
        expect(
          withOverrides(
            'dependency_overrides:\n'
            '  gg_log:\n'
            '    git:\n'
            '      url: git@github.com:user/gg_log.git\n'
            '      ref: feature123\n',
          ),
          isFalse,
        );
      });

      test('is false for a plain version override', () {
        expect(
          withOverrides('dependency_overrides:\n  gg_log: ^1.0.0\n'),
          isFalse,
        );
      });

      test('is true for a path override', () {
        expect(
          withOverrides('dependency_overrides:\n  gg_log:\n    path: ../x'),
          isTrue,
        );
      });

      test('is true when dependency_overrides is no mapping', () {
        expect(withOverrides('dependency_overrides: broken\n'), isTrue);
      });

      test('is true for an unparsable file', () {
        expect(withOverrides('dependency_overrides:\n  - : :\n\t x'), isTrue);
      });
    });
  });
}
