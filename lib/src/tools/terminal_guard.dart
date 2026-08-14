// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';

/// Signature of the check whether stdin is attached to a terminal.
typedef HasTerminal = bool Function();

/// The real check, asking the process' stdin.
// coverage:ignore-start
bool defaultHasTerminal() => stdin.hasTerminal;
// coverage:ignore-end

/// Throws when stdin is not a terminal, so headless runs (CI, scripts,
/// pipes) fail fast with an actionable message instead of hanging forever
/// on an interactive prompt.
///
/// [what] names the prompt (e.g. `the merge message prompt`); [alternative]
/// tells the user how to supply the value non-interactively. [hasTerminal]
/// replaces the stdin check in tests — `dart test` hands the test isolate a
/// stdin whose `hasTerminal` differs per platform, so the check must be
/// injected instead of observed.
void throwWhenNotATerminal(
  String what,
  String alternative, {
  HasTerminal hasTerminal = defaultHasTerminal,
}) {
  if (!hasTerminal()) {
    throw Exception(
      cError(
        'Cannot show $what: stdin is not a terminal. '
        'For headless runs, $alternative.',
      ),
    );
  }
}
