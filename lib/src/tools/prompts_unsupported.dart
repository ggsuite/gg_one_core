// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'prompts.dart';

/// SGR sequence switching the terminal back to its default colors.
const String colorOff = '\x1B[0m';

/// Builds the prompts of a build without `dart:ffi` — Wasm, for example.
GgPrompts createDefaultPrompts() => const UnsupportedPrompts();

/// Refuses every prompt with a message telling the user what to do instead.
///
/// `package:interact` draws prompts through `dart:ffi`, which a Wasm build
/// does not have. An embedder that can ask the user itself replaces this by
/// assigning [GgPrompts.current].
class UnsupportedPrompts extends GgPrompts {
  /// Default constructor
  const UnsupportedPrompts();

  @override
  Future<int> select({
    required String prompt,
    required List<String> options,
    int initialIndex = 0,
  }) => throw GgPromptsUnsupportedError(prompt);

  @override
  Future<String> input({
    required String prompt,
    String? defaultValue,
    String? initialText,
    bool asMessageEditor = false,
  }) => throw GgPromptsUnsupportedError(prompt);
}
