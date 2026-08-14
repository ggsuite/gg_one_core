// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_publish/gg_publish.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pub_semver/pub_semver.dart';

import 'prompts.dart';
import 'terminal_guard.dart';

/// Abstraction over interactive selection used by [VersionSelector].
abstract class InteractAdapter {
  /// Lets the user choose one of the given [options] and returns the index.
  ///
  /// [initialIndex] is the entry the cursor starts on — how a previously
  /// recorded answer becomes the pre-selected default of a re-run.
  Future<int> choose({
    required String message,
    required List<String> options,
    int initialIndex = 0,
  });
}

/// Default implementation of [InteractAdapter] that delegates to `interact`.
// coverage:ignore-start
class DefaultInteractAdapter implements InteractAdapter {
  @override
  Future<int> choose({
    required String message,
    required List<String> options,
    int initialIndex = 0,
  }) async {
    throwWhenNotATerminal(
      'the version-increment prompt',
      'provide versionIncrement via .gg/publish_config.json '
          '(gg do configure-publish) or --config',
    );
    return await GgPrompts.current.select(
      prompt: message,
      options: options,
      initialIndex: initialIndex,
    );
  }
}
// coverage:ignore-end

/// Lets the user interactively select the next version increment.
class VersionSelector {
  /// Constructor.
  VersionSelector({InteractAdapter? adapter})
    // coverage:ignore-start
    : _adapter = adapter ?? DefaultInteractAdapter();
  // coverage:ignore-end

  final InteractAdapter _adapter;

  /// Asks the user which [VersionIncrement] should be applied to
  /// [currentVersion].
  ///
  /// [preselect] is the answer a previous run recorded. It starts the cursor
  /// on that entry instead of skipping the prompt: the question is always
  /// asked, so a choice made earlier stays correctable.
  Future<VersionIncrement> selectIncrement({
    required Version currentVersion,
    VersionIncrement? preselect,
  }) async {
    final patchVersion = Version(
      currentVersion.major,
      currentVersion.minor,
      currentVersion.patch + 1,
    );
    final minorVersion = Version(
      currentVersion.major,
      currentVersion.minor + 1,
      0,
    );
    final majorVersion = Version(currentVersion.major + 1, 0, 0);

    final options = <String>[
      'Patch (${currentVersion.toString()} -> ${patchVersion.toString()})',
      'Minor (${currentVersion.toString()} -> ${minorVersion.toString()})',
      'Major (${currentVersion.toString()} -> ${majorVersion.toString()})',
    ];

    final index = await _adapter.choose(
      message: cAction('Select version increment:'),
      options: options,
      initialIndex: preselect == null ? 0 : _indexOf(preselect),
    );

    return _incrementAt(index);
  }

  /// The option index [increment] is offered at — the inverse of
  /// [_incrementAt], kept next to it so the two cannot drift.
  static int _indexOf(VersionIncrement increment) {
    switch (increment) {
      case VersionIncrement.patch:
        return 0;
      case VersionIncrement.minor:
        return 1;
      case VersionIncrement.major:
        return 2;
    }
  }

  static VersionIncrement _incrementAt(int index) {
    switch (index) {
      case 1:
        return VersionIncrement.minor;
      case 2:
        return VersionIncrement.major;
      default:
        // Index 0 and — defensively — any unexpected index mean patch.
        return VersionIncrement.patch;
    }
  }
}

// .............................................................................
/// A Mock for the VersionSelector class using Mocktail
class MockVersionSelector extends Mock implements VersionSelector {}
