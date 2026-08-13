// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _MockProcessWrapper extends Mock implements GgProcessWrapper {}

// .............................................................................
void main() {
  late Directory d;
  late _MockProcessWrapper processWrapper;
  late PubGetOffline pubGetOffline;
  final messages = <String>[];

  setUp(() {
    d = Directory.systemTemp.createTempSync();
    processWrapper = _MockProcessWrapper();
    pubGetOffline = PubGetOffline(
      ggLog: messages.add,
      processWrapper: processWrapper,
    );
    messages.clear();
  });

  tearDown(() {
    d.deleteSync(recursive: true);
  });

  group('PubGetOffline', () {
    test('runs "dart pub get --offline" and logs the Running "..." message '
        'when pubspec.yaml is present', () async {
      File(p.join(d.path, 'pubspec.yaml')).writeAsStringSync('name: x');

      when(
        () => processWrapper.run('dart', [
          'pub',
          'get',
          '--offline',
        ], workingDirectory: d.path),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      await pubGetOffline.exec(directory: d, ggLog: messages.add);

      verify(
        () => processWrapper.run('dart', [
          'pub',
          'get',
          '--offline',
        ], workingDirectory: d.path),
      ).called(1);

      expect(
        messages.any((m) => m.contains('Running "dart pub get --offline"')),
        isTrue,
      );
      expect(messages.any((m) => m.contains('»')), isFalse);
    });

    test('skips when pubspec.yaml is missing', () async {
      await pubGetOffline.exec(directory: d, ggLog: messages.add);

      verifyNever(
        () => processWrapper.run(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
        ),
      );
      expect(messages, isEmpty);
    });

    test('throws when pub get fails', () async {
      File(p.join(d.path, 'pubspec.yaml')).writeAsStringSync('name: x');

      when(
        () => processWrapper.run('dart', [
          'pub',
          'get',
          '--offline',
        ], workingDirectory: d.path),
      ).thenAnswer((_) async => ProcessResult(0, 1, '', 'pub error'));

      expect(
        () => pubGetOffline.exec(directory: d, ggLog: messages.add),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('pub get --offline'),
          ),
        ),
      );
    });
  });
}
