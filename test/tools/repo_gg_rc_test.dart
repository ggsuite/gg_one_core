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

  group('RepoGgRc', () {
    test('creates the file with defaults when missing', () {
      File(p.join(d.path, '.gitignore'))
          .writeAsStringSync('.gg/*\n!.gg/gg.json\n');
      final rc = RepoGgRc.load(d);
      expect(rc.upgradeMajorVersions, isTrue);
      expect(rc.enableChecks, isTrue);
      expect(repoGgRcFile(d).readAsStringSync(), RepoGgRc.template);
      expect(
        File(p.join(d.path, '.gitignore')).readAsStringSync(),
        '.gg/*\n!.gg/gg_rc.jsonc\n!.gg/gg.json\n',
      );

      // A second load parses the template and keeps .gitignore
      expect(RepoGgRc.load(d).upgradeMajorVersions, isTrue);
      expect(
        '!.gg/gg_rc.jsonc'.allMatches(
          File(p.join(d.path, '.gitignore')).readAsStringSync(),
        ),
        hasLength(1),
      );
    });

    test('leaves .gitignore without .gg/* alone', () {
      File(p.join(d.path, '.gitignore')).writeAsStringSync('build/\n');
      RepoGgRc.load(d);
      expect(File(p.join(d.path, '.gitignore')).readAsStringSync(), 'build/\n');
    });

    test('reads upgradeMajorVersions: false', () {
      repoGgRcFile(d)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{ // c\n "upgradeMajorVersions": false, }');
      expect(RepoGgRc.load(d).upgradeMajorVersions, isFalse);
    });

    test('reads enableChecks: false', () {
      expect(
        RepoGgRc.fromJsonString('{"enableChecks": false}').enableChecks,
        isFalse,
      );
      expect(
        () => RepoGgRc.fromJsonString('{"enableChecks": "no"}'),
        throwsFormatException,
      );
    });

    test('read does not create the file', () {
      expect(RepoGgRc.read(d).enableChecks, isTrue);
      expect(repoGgRcFile(d).existsSync(), isFalse);
    });

    test('defaults missing keys', () {
      expect(RepoGgRc.fromJsonString('{}').upgradeMajorVersions, isTrue);
    });

    test('rejects invalid content', () {
      expect(() => RepoGgRc.fromJsonString('{'), throwsFormatException);
      expect(() => RepoGgRc.fromJsonString('[]'), throwsFormatException);
      expect(
        () => RepoGgRc.fromJsonString('{"upgradeMajorVersions": 1}'),
        throwsFormatException,
      );
    });
  });
}
