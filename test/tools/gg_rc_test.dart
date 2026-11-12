// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_one_core/gg_one_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory d;

  setUp(() => d = Directory.systemTemp.createTempSync('gg_rc_test'));
  tearDown(() => d.deleteSync(recursive: true));

  group('GgRc', () {
    test('creates the file with defaults when missing', () {
      File(p.join(d.path, '.gitignore'))
          .writeAsStringSync('.gg/*\n!.gg/gg.json\n');
      final rc = GgRc.load(d);
      expect(rc.upgradeMajorVersions, isTrue);
      expect(rc.enableChecks, isTrue);
      expect(ggRcFile(d).readAsStringSync(), GgRc.template);
      expect(
        File(p.join(d.path, '.gitignore')).readAsStringSync(),
        '.gg/*\n!.gg/gg_rc.jsonc\n!.gg/gg.json\n',
      );

      // A second load parses the template and keeps .gitignore
      expect(GgRc.load(d).upgradeMajorVersions, isTrue);
      expect(
        '!.gg/gg_rc.jsonc'.allMatches(
          File(p.join(d.path, '.gitignore')).readAsStringSync(),
        ),
        hasLength(1),
      );
    });

    test('leaves .gitignore without .gg/* alone', () {
      File(p.join(d.path, '.gitignore')).writeAsStringSync('build/\n');
      GgRc.load(d);
      expect(File(p.join(d.path, '.gitignore')).readAsStringSync(), 'build/\n');
    });

    test('reads upgradeMajorVersions: false', () {
      ggRcFile(d)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{ // c\n "upgradeMajorVersions": false, }');
      expect(GgRc.load(d).upgradeMajorVersions, isFalse);
    });

    test('reads enableChecks: false', () {
      expect(
        GgRc.fromJsonString('{"enableChecks": false}').enableChecks,
        isFalse,
      );
      expect(
        () => GgRc.fromJsonString('{"enableChecks": "no"}'),
        throwsFormatException,
      );
    });

    test('defaults missing keys', () {
      expect(GgRc.fromJsonString('{}').upgradeMajorVersions, isTrue);
    });

    test('rejects invalid content', () {
      expect(() => GgRc.fromJsonString('{'), throwsFormatException);
      expect(() => GgRc.fromJsonString('[]'), throwsFormatException);
      expect(
        () => GgRc.fromJsonString('{"upgradeMajorVersions": 1}'),
        throwsFormatException,
      );
    });
  });
}
