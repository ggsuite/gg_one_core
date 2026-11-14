// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import 'package:gg_log/gg_log.dart';
import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_process/gg_process.dart';
import 'package:test/test.dart';

// .............................................................................
/// A machine with 22 processors and the given `GG_PARALLEL`.
class _Platform extends GgPlatformDelegate {
  _Platform({String? parallel})
    : environment = {GgParallelism.environmentVariable: ?parallel};

  @override
  final Map<String, String> environment;

  @override
  int get numberOfProcessors => 22;
}

void main() {
  final messages = <String>[];
  final GgLog ggLog = messages.add;
  final checks = Checks(ggLog: ggLog);

  group('Checks', () {
    group('all', () {
      test('should provide a list of all checks', () {
        expect(checks.all, hasLength(15));
        expect(checks.all, [
          checks.pubGetOffline,
          checks.analyze,
          checks.build,
          checks.format,
          checks.tests,
          checks.packageJsonScripts,
          checks.pana,
          checks.npmLoggedIn,
          checks.noPubspecOverrides,
          checks.isPushed,
          checks.isCommitted,
          checks.isVersioned,
          checks.noFutureVersions,
          checks.isPublished,
          checks.isUpgraded,
        ]);
      });
    });

    group('tests', () {
      final platform = GgPlatformDelegate.current;
      tearDown(() => GgPlatformDelegate.current = platform);

      test('leaves a test run on its own to the test runner', () {
        // The machine would take four runs, but this one is alone.
        GgPlatformDelegate.current = _Platform();
        expect(GgParallelism.heavy, 4);
        expect(checks.tests.concurrency!(), isNull);
        expect(checks.tests.timeoutFactor!(), isNull);
      });

      test('lets test runs that go at the same time share the '
          'machine', () async {
        GgPlatformDelegate.current = _Platform();
        final slots = TaskSlots.heavy();
        final underWay = Completer<void>();
        final bothAsked = Completer<void>();
        final concurrency = <int?>[];
        final timeoutFactor = <int?>[];

        final runs = [
          for (var i = 0; i < 2; i++)
            slots.use(() async {
              await underWay.future;
              concurrency.add(checks.tests.concurrency!());
              timeoutFactor.add(checks.tests.timeoutFactor!());
              if (concurrency.length == 2) {
                bothAsked.complete();
              }
              await bothAsked.future;
            }),
        ];
        underWay.complete();
        await Future.wait(runs);

        // Two runs hold a heavy slot: each gets half of what one run would
        // take, and its tests four times their usual time — two more runs
        // may join.
        expect(concurrency, [6, 6]);
        expect(timeoutFactor, [4, 4]);
      });

      test('leaves every test run to the test runner with '
          'GG_PARALLEL=1', () async {
        GgPlatformDelegate.current = _Platform(parallel: '1');
        final slots = TaskSlots.heavy();

        await slots.use(() async {
          expect(checks.tests.concurrency!(), isNull);
          expect(checks.tests.timeoutFactor!(), isNull);
        });
      });
    });
  });
}
