// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_publish/gg_publish.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

class _MockInteractAdapter extends Mock implements InteractAdapter {}

void main() {
  group('VersionSelector', () {
    late _MockInteractAdapter adapter;
    late VersionSelector selector;

    setUp(() {
      adapter = _MockInteractAdapter();
      selector = VersionSelector(adapter: adapter);
    });

    test('returns patch / minor / major based on user selection', () async {
      final current = Version(1, 2, 3);

      when(
        () => adapter.choose(
          message: any(named: 'message'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async => 0);

      final patch = await selector.selectIncrement(currentVersion: current);
      expect(patch, VersionIncrement.patch);

      when(
        () => adapter.choose(
          message: any(named: 'message'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async => 1);

      final minor = await selector.selectIncrement(currentVersion: current);
      expect(minor, VersionIncrement.minor);

      when(
        () => adapter.choose(
          message: any(named: 'message'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async => 2);

      final major = await selector.selectIncrement(currentVersion: current);
      expect(major, VersionIncrement.major);
    });

    test('falls back to patch on unexpected index', () async {
      final current = Version(1, 2, 3);

      when(
        () => adapter.choose(
          message: any(named: 'message'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async => 99);

      final increment = await selector.selectIncrement(currentVersion: current);
      expect(increment, VersionIncrement.patch);
    });

    test('builds choice labels from current version', () async {
      final current = Version(1, 2, 3);

      late List<String> capturedOptions;

      when(
        () => adapter.choose(
          message: any(named: 'message'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((invocation) async {
        capturedOptions = invocation.namedArguments[#options] as List<String>;
        return 0;
      });

      await selector.selectIncrement(currentVersion: current);

      expect(capturedOptions.length, 3);
      expect(capturedOptions[0], 'Patch (1.2.3 -> 1.2.4)');
      expect(capturedOptions[1], 'Minor (1.2.3 -> 1.3.0)');
      expect(capturedOptions[2], 'Major (1.2.3 -> 2.0.0)');
    });
  });
}
