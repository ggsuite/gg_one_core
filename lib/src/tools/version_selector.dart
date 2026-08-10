// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
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
  Future<int> choose({required String message, required List<String> options});
}

/// Default implementation of [InteractAdapter] that delegates to `interact`.
// coverage:ignore-start
class DefaultInteractAdapter implements InteractAdapter {
  @override
  Future<int> choose({
    required String message,
    required List<String> options,
  }) async {
    throwWhenNotATerminal(
      'the version-increment prompt',
      'provide version_increment via .gg/gg-publish.json '
          '(gg do configure-publish) or --config',
    );
    return GgPrompts.current.select(prompt: message, options: options);
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
  Future<VersionIncrement> selectIncrement({
    required Version currentVersion,
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
    );

    switch (index) {
      case 0:
        return VersionIncrement.patch;
      case 1:
        return VersionIncrement.minor;
      case 2:
        return VersionIncrement.major;
      default:
        // Fallback to patch when an unexpected index is returned.
        return VersionIncrement.patch;
    }
  }
}

// .............................................................................
/// A Mock for the VersionSelector class using Mocktail
class MockVersionSelector extends Mock implements VersionSelector {}
