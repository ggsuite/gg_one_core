// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_json/gg_json.dart' show deeplEquals;
import 'package:gg_publish/gg_publish.dart' show VersionIncrement;
import 'package:path/path.dart' as p;

import 'commit_message.dart';
import 'publish_config.dart';

/// The name of the file holding the answered publish inputs of a repository.
const String repoPublishConfigFileName = 'publish_config.json';

/// The root key every `publish_config.json` wraps its content in.
const String publishConfigRootKey = 'publishConfig';

/// The `publish_config.json` of the repository at [repoDir].
File repoPublishConfigFile(Directory repoDir) =>
    File(p.join(repoDir.path, '.gg', repoPublishConfigFileName));

/// The answers that drive a repository's commits and its release — the file
/// the AI maintains while it works.
///
/// It holds only *inputs*: the next commit message, the messages of the
/// commits already made, the pull-request title and the version increment.
/// The progress of a publish run lives in `publish_state.json`, so a
/// `--restart` can discard the run without discarding the answers.
///
/// The file is written in **camelCase**, deliberately different from the
/// legacy snake_case `gg-publish.json`: a new schema with no back-compat
/// obligations reads better in one consistent case than in a mixed one. The
/// legacy reader keeps its own keys and is never written again.
class RepoPublishConfig {
  /// Creates a repository publish config.
  RepoPublishConfig({
    this.mergeMessage,
    this.versionIncrement,
    this.nextCommitMessage,
    List<CommitMessage>? commits,
  }) : commits = List<CommitMessage>.unmodifiable(
         commits ?? const <CommitMessage>[],
       );

  /// The pull-request title of this repository, and the message of the merge
  /// commit the release produces. Initialized from the ticket description.
  final String? mergeMessage;

  /// How the next release bumps the version.
  final VersionIncrement? versionIncrement;

  /// The message proposed by the next `gg do commit`.
  ///
  /// It is **not** consumed by committing: the AI keeps it up to date with
  /// whatever is currently uncommitted, so the default a commit prompt shows
  /// always describes the pending work.
  final CommitMessage? nextCommitMessage;

  /// The messages of the commits this ticket already made in this repository,
  /// in commit order. Rendered as the pull-request description. Written by
  /// `gg do commit`, never by hand.
  final List<CommitMessage> commits;

  /// Reads the config of [repoDir], or null when the file does not exist.
  static RepoPublishConfig? tryLoad(Directory repoDir) {
    final file = repoPublishConfigFile(repoDir);
    if (!file.existsSync()) return null;
    return RepoPublishConfig.fromJsonString(
      file.readAsStringSync(),
      where: file.path,
    );
  }

  /// Parses [raw]. [where] names the source in error messages.
  factory RepoPublishConfig.fromJsonString(
    String raw, {
    required String where,
  }) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw FormatException('$where is not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('$where must contain a JSON object.');
    }
    return RepoPublishConfig.fromJson(decoded, where: where);
  }

  /// Reads a config from the outer [json] — the map carrying the
  /// [publishConfigRootKey] wrapper. [where] names the source in errors.
  factory RepoPublishConfig.fromJson(
    Map<String, dynamic> json, {
    required String where,
  }) {
    final inner = json[publishConfigRootKey];
    if (inner is! Map<String, dynamic>) {
      throw FormatException(
        '$where: "$publishConfigRootKey" must be a JSON object.',
      );
    }

    final increment = inner['versionIncrement'];
    VersionIncrement? parsedIncrement;
    if (increment != null) {
      if (increment is! String ||
          !allowedVersionIncrements.contains(increment)) {
        throw FormatException(
          '$where: "versionIncrement" must be one of '
          '${allowedVersionIncrements.join(", ")} (was "$increment").',
        );
      }
      parsedIncrement = parseVersionIncrement(increment);
    }

    final mergeMessage = inner['mergeMessage'];
    if (mergeMessage != null && mergeMessage is! String) {
      throw FormatException('$where: "mergeMessage" must be a string.');
    }

    final next = inner['nextCommitMessage'];
    CommitMessage? nextCommitMessage;
    if (next != null) {
      if (next is! Map<String, dynamic>) {
        throw FormatException(
          '$where: "nextCommitMessage" must be a JSON object.',
        );
      }
      nextCommitMessage = CommitMessage.fromJson(
        next,
        where: '$where nextCommitMessage',
      );
    }

    final rawCommits = inner['commits'];
    final commits = <CommitMessage>[];
    if (rawCommits != null) {
      if (rawCommits is! List) {
        throw FormatException('$where: "commits" must be a list.');
      }
      for (var i = 0; i < rawCommits.length; i++) {
        final commit = rawCommits[i];
        if (commit is! Map<String, dynamic>) {
          throw FormatException('$where: "commits[$i]" must be a JSON object.');
        }
        commits.add(
          CommitMessage.fromJson(commit, where: '$where commits[$i]'),
        );
      }
    }

    return RepoPublishConfig(
      mergeMessage: (mergeMessage as String?)?.trim().isEmpty ?? true
          ? null
          : (mergeMessage as String).trim(),
      versionIncrement: parsedIncrement,
      nextCommitMessage: nextCommitMessage,
      commits: commits,
    );
  }

  /// This config as a JSON map, wrapped in [publishConfigRootKey]. Null and
  /// empty fields are omitted so a hand-edited file stays readable.
  Map<String, dynamic> toJson() => <String, dynamic>{
    publishConfigRootKey: <String, dynamic>{
      if (mergeMessage != null) 'mergeMessage': mergeMessage,
      if (versionIncrement != null) 'versionIncrement': versionIncrement!.name,
      if (nextCommitMessage != null)
        'nextCommitMessage': nextCommitMessage!.toJson(),
      if (commits.isNotEmpty)
        'commits': [for (final commit in commits) commit.toJson()],
    },
  };

  /// This config pretty-printed as a two-space-indented JSON string.
  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Persists this config to [file], creating the `.gg/` folder when missing.
  Future<void> save({required File file}) async {
    final parent = file.parent;
    if (!parent.existsSync()) {
      await parent.create(recursive: true);
    }
    await file.writeAsString('${toJsonString()}\n');
  }

  /// A copy that records [message] among the [commits].
  ///
  /// [nextCommitMessage] is deliberately left untouched — it is the standing
  /// proposal for the next commit, not a buffer that committing empties. A
  /// message that is already recorded is not appended twice, so re-running a
  /// commit after a partial failure cannot duplicate an entry. Equality is a
  /// deep JSON comparison, so a message that gained a detail counts as new.
  RepoPublishConfig withCommitted(CommitMessage message) {
    final candidate = message.toJson();
    final alreadyRecorded = commits.any(
      (commit) => deeplEquals(commit.toJson(), candidate),
    );
    if (alreadyRecorded) return this;
    return copyWith(commits: [...commits, message]);
  }

  /// A copy with the given fields replaced. Passing null keeps the current
  /// value; use [clearNextCommitMessage] to remove the proposal explicitly.
  RepoPublishConfig copyWith({
    String? mergeMessage,
    VersionIncrement? versionIncrement,
    CommitMessage? nextCommitMessage,
    List<CommitMessage>? commits,
    bool clearNextCommitMessage = false,
  }) => RepoPublishConfig(
    mergeMessage: mergeMessage ?? this.mergeMessage,
    versionIncrement: versionIncrement ?? this.versionIncrement,
    nextCommitMessage: clearNextCommitMessage
        ? null
        : nextCommitMessage ?? this.nextCommitMessage,
    commits: commits ?? this.commits,
  );

  /// The recorded [commits] rendered as a pull-request description, or null
  /// when nothing was recorded. Each commit becomes a bullet, its details
  /// indented below it.
  String? get pullRequestBody {
    if (commits.isEmpty) return null;
    final buffer = StringBuffer();
    for (final commit in commits) {
      buffer.writeln('- ${commit.firstLine}');
      for (final detail in commit.details) {
        buffer.writeln('  - $detail');
      }
    }
    return buffer.toString().trimRight();
  }
}
