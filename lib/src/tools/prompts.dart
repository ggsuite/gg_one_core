// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'prompts_interact.dart'
    if (dart.library.js_interop) 'prompts_unsupported.dart'
    as impl;

/// Asks the user a question on the terminal.
///
/// Every interactive prompt in the gg suite goes through
/// [GgPrompts.current]. Two reasons:
///
/// 1. `package:interact`, which draws the prompts, reaches `dart:ffi`
///    through `package:dart_console` — a library `dart compile wasm` does
///    not have. The conditional import above keeps it out of a Wasm build
///    entirely.
/// 2. An embedder that has no terminal of its own — gg running inside a
///    Node process, say — can answer the prompts itself by assigning
///    [GgPrompts.current].
///
/// On a native build [current] draws real prompts. In a Wasm build it
/// throws [GgPromptsUnsupportedError] until an embedder replaces it.
abstract class GgPrompts {
  /// Default constructor
  const GgPrompts();

  /// Lets the user pick one of [options] and returns the index picked.
  ///
  /// Asynchronous on purpose. Nothing in gg needs the answer synchronously
  /// — every caller already awaits — and a synchronous contract would
  /// force an embedder to block on its input, which not every platform
  /// lets it do. `@tssuite/gg-js` uses Node's `readline` because of this.
  Future<int> select({
    required String prompt,
    required List<String> options,
    int initialIndex = 0,
  });

  /// Lets the user edit a line of text and returns what they left behind.
  ///
  /// [initialText] is put into the edit buffer, [defaultValue] is what an
  /// empty buffer means. [asMessageEditor] switches to the wider styling
  /// used for commit and merge messages.
  Future<String> input({
    required String prompt,
    String? defaultValue,
    String? initialText,
    bool asMessageEditor = false,
  });

  // ...........................................................................
  /// The prompts the gg suite currently asks its questions with.
  static GgPrompts get current => _current;

  /// Replaces the prompts. Pass `null` to restore [defaultPrompts].
  static set current(GgPrompts? prompts) =>
      _current = prompts ?? defaultPrompts;

  /// The prompts of the platform gg was compiled for.
  static final GgPrompts defaultPrompts = impl.createDefaultPrompts();

  static GgPrompts _current = defaultPrompts;
}

// .............................................................................
/// Thrown when gg wants to ask the user something but the platform it runs
/// on cannot draw prompts and no embedder has supplied any.
class GgPromptsUnsupportedError extends UnsupportedError {
  /// Default constructor
  GgPromptsUnsupportedError(String what)
    : super(
        'Cannot show $what: this build of gg has no interactive prompts. '
        'Answer the question on the command line instead, or assign '
        'GgPrompts.current.',
      );
}
