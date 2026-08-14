// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

/// Reads the ticket description from `<ticketDir>/ticket.json`, or returns
/// `null`
/// when the file is missing, is not a JSON object, is malformed, or carries an
/// empty description.
///
/// The description is the human-written summary of the ticket and therefore
/// the natural default for the messages gg writes on the user's behalf — in
/// particular for the commit that saves pending user changes before a
/// bookkeeping commit.
String? readTicketDescription(Directory ticketDir) {
  final file = File(path.join(ticketDir.path, 'ticket.json'));
  if (!file.existsSync()) {
    return null;
  }

  final dynamic decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } catch (_) {
    // A hand-edited / truncated ticket.json must not crash the caller.
    return null;
  }
  if (decoded is! Map<String, dynamic>) {
    return null;
  }

  final description = decoded['description']?.toString().trim();
  if (description == null || description.isEmpty) {
    return null;
  }

  return description;
}

/// Reads the ticket description for the repository at [repoDir], or `null`
/// when the repository is not part of a ticket.
///
/// The `ticket.json` file lives in the ticket folder, which is an ancestor of
/// the repository (`<ticket>/<org>/<repo>`), so the ancestors are walked upward
/// until a `ticket.json` file answers or the filesystem root is reached.
String? readTicketDescriptionForRepo(Directory repoDir) {
  var current = repoDir.absolute;
  while (true) {
    final description = readTicketDescription(current);
    if (description != null) {
      return description;
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      return null;
    }
    current = parent;
  }
}
