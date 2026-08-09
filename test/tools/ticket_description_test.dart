// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_git/gg_git_test_helpers.dart';
import 'package:gg_one_core/gg_one_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory d;

  setUp(() async {
    d = await initTestDir();
  });

  group('readTicketDescription(ticketDir)', () {
    test('returns the description of a valid .ticket file', () {
      File('${d.path}/.ticket').writeAsStringSync(
        jsonEncode({'description': 'Improve commit behavior'}),
      );
      expect(readTicketDescription(d), 'Improve commit behavior');
    });

    test('returns null when the file is missing', () {
      expect(readTicketDescription(d), isNull);
    });

    test('returns null for malformed or non-object JSON', () {
      final file = File('${d.path}/.ticket');

      file.writeAsStringSync('{ not json');
      expect(readTicketDescription(d), isNull);

      file.writeAsStringSync('[1, 2, 3]');
      expect(readTicketDescription(d), isNull);
    });

    test('returns null for a missing or empty description', () {
      final file = File('${d.path}/.ticket');

      file.writeAsStringSync(jsonEncode({'other': 'x'}));
      expect(readTicketDescription(d), isNull);

      file.writeAsStringSync(jsonEncode({'description': '   '}));
      expect(readTicketDescription(d), isNull);
    });
  });

  group('readTicketDescriptionForRepo(repoDir)', () {
    test('finds the .ticket file above the repository', () {
      // The layout of a real ticket: <ticket>/.ticket + <ticket>/<org>/<repo>.
      File('${d.path}/.ticket').writeAsStringSync(
        jsonEncode({'description': 'Improve commit behavior'}),
      );
      final repo = Directory('${d.path}/ggsuite/gg_git')
        ..createSync(recursive: true);

      expect(readTicketDescriptionForRepo(repo), 'Improve commit behavior');
    });

    test('returns null when no ancestor carries a .ticket file', () {
      final repo = Directory('${d.path}/ggsuite/gg_git')
        ..createSync(recursive: true);
      expect(readTicketDescriptionForRepo(repo), isNull);
    });
  });
}
