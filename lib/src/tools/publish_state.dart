// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'publish_config.dart';

/// The name of the file holding the progress of a publish run.
const String publishStateFileName = 'publish_state.json';

/// The `publish_state.json` of the repository or ticket at [dir].
///
/// The same class serves both scopes: a repository records its own steps, the
/// ticket folder records the answers that span all its repositories
/// ([PublishState.deleteTicket]).
File publishStateFile(Directory dir) =>
    File(p.join(dir.path, '.gg', publishStateFileName));

/// The progress of a publish run — everything that is *state*, never an
/// answer the user or the AI gave.
///
/// It is kept apart from `publish_config.json` on purpose: `--restart` throws
/// the state away and keeps the answers, and a leftover state file is the one
/// thing that makes a `--continue` legitimate.
///
/// Unlike the legacy [PublishConfig] this file is written in **camelCase** —
/// a new schema with no back-compat obligations, consistent with
/// `publish_config.json`. The legacy reader keeps its snake_case keys.
class PublishState {
  /// Creates a publish state.
  PublishState({
    this.status,
    List<String>? doneSteps,
    this.branch,
    this.pr,
    this.channel,
    this.deleteTicket,
    this.deleteFeatureBranch,
  }) : doneSteps = List<String>.unmodifiable(doneSteps ?? const <String>[]);

  /// The publish progress marker, one of [allowedPublishStatuses]; null when
  /// no run has touched this repository yet.
  final String? status;

  /// The publish steps that already completed, in completion order.
  final List<String> doneSteps;

  /// The feature branch the publish started on. A resumed run may find HEAD
  /// on the default branch already, so the branch must not be re-read there.
  final String? branch;

  /// Whether the final merge goes through an auto-merge pull request.
  final bool? pr;

  /// The release channel, one of [allowedReleaseChannels]; null means
  /// `stable`.
  final String? channel;

  /// Whether the ticket folder is removed after the publish (ticket scope).
  final bool? deleteTicket;

  /// Whether the feature branch is deleted after the publish.
  final bool? deleteFeatureBranch;

  /// Reads the state of [dir], or null when no state file exists.
  ///
  /// A malformed file throws — a resume must never silently continue from a
  /// state nobody could read.
  static PublishState? tryLoad(Directory dir) {
    final file = publishStateFile(dir);
    if (!file.existsSync()) return null;
    return PublishState.fromJsonString(
      file.readAsStringSync(),
      where: file.path,
    );
  }

  /// Parses [raw]. [where] names the source in error messages.
  factory PublishState.fromJsonString(String raw, {required String where}) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw FormatException('$where is not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('$where must contain a JSON object.');
    }
    return PublishState.fromJson(decoded, where: where);
  }

  /// Reads a state from [json]. [where] names the source in error messages.
  factory PublishState.fromJson(
    Map<String, dynamic> json, {
    required String where,
  }) => PublishState(
    status: _readOneOf(
      json,
      key: 'status',
      allowed: allowedPublishStatuses,
      where: where,
    ),
    doneSteps: _readSteps(json, where: where),
    branch: _readString(json, key: 'branch', where: where),
    pr: _readBool(json, key: 'pr', where: where),
    channel: _readOneOf(
      json,
      key: 'channel',
      allowed: allowedReleaseChannels,
      where: where,
    ),
    deleteTicket: _readBool(json, key: 'deleteTicket', where: where),
    deleteFeatureBranch: _readBool(
      json,
      key: 'deleteFeatureBranch',
      where: where,
    ),
  );

  /// This state as a JSON map, omitting null and empty fields.
  Map<String, dynamic> toJson() => <String, dynamic>{
    if (status != null) 'status': status,
    if (doneSteps.isNotEmpty) 'doneSteps': doneSteps,
    if (branch != null) 'branch': branch,
    if (pr != null) 'pr': pr,
    if (channel != null) 'channel': channel,
    if (deleteTicket != null) 'deleteTicket': deleteTicket,
    if (deleteFeatureBranch != null) 'deleteFeatureBranch': deleteFeatureBranch,
  };

  /// This state pretty-printed as a two-space-indented JSON string.
  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Persists this state to [file], creating the `.gg/` folder when missing.
  Future<void> save({required File file}) async {
    final parent = file.parent;
    if (!parent.existsSync()) {
      await parent.create(recursive: true);
    }
    await file.writeAsString('${toJsonString()}\n');
  }

  /// Whether the publish step [step] already completed.
  bool isStepDone(String step) => doneSteps.contains(step);

  /// Whether any publish step completed — i.e. this file is the leftover of
  /// an unfinished run.
  bool get hasStepProgress => doneSteps.isNotEmpty;

  /// Whether this state carries the single registry marker older gg versions
  /// wrote. Such a run cannot say *which* registry it reached, so the publish
  /// flow re-asks each of them instead of trusting the marker.
  bool get hasLegacyRegistryStep =>
      doneSteps.contains(legacyPublishRegistryStep);

  /// A copy with [step] appended to [doneSteps]. Throws [ArgumentError] for
  /// names outside [writablePublishSteps] — the legacy names are readable but
  /// must never be written again. Marking a done step is a no-op.
  PublishState withStepDone(String step) {
    if (!writablePublishSteps.contains(step)) {
      throw ArgumentError.value(step, 'step', 'unknown publish step');
    }
    if (isStepDone(step)) return this;
    return copyWith(doneSteps: [...doneSteps, step]);
  }

  /// A copy carrying the progress marker [status]. Throws [ArgumentError] for
  /// values outside [allowedPublishStatuses].
  PublishState withStatus(String status) {
    if (!allowedPublishStatuses.contains(status)) {
      throw ArgumentError.value(status, 'status', 'unknown publish status');
    }
    return copyWith(status: status);
  }

  /// A copy with the given fields replaced. Passing null keeps the current
  /// value — these fields are only ever set, never cleared.
  PublishState copyWith({
    String? status,
    List<String>? doneSteps,
    String? branch,
    bool? pr,
    String? channel,
    bool? deleteTicket,
    bool? deleteFeatureBranch,
  }) => PublishState(
    status: status ?? this.status,
    doneSteps: doneSteps ?? this.doneSteps,
    branch: branch ?? this.branch,
    pr: pr ?? this.pr,
    channel: channel ?? this.channel,
    deleteTicket: deleteTicket ?? this.deleteTicket,
    deleteFeatureBranch: deleteFeatureBranch ?? this.deleteFeatureBranch,
  );

  // ...........................................................................
  static List<String>? _readSteps(
    Map<String, dynamic> json, {
    required String where,
  }) {
    final v = json['doneSteps'];
    if (v == null) return null;
    if (v is! List) {
      throw FormatException('$where: "doneSteps" must be a list of strings.');
    }
    final steps = <String>[];
    for (final step in v) {
      if (step is! String || !allowedPublishSteps.contains(step)) {
        throw FormatException(
          '$where: "doneSteps" entries must be one of '
          '${allowedPublishSteps.join(", ")} (was "$step").',
        );
      }
      if (!steps.contains(step)) steps.add(step);
    }
    return steps;
  }

  static String? _readString(
    Map<String, dynamic> json, {
    required String key,
    required String where,
  }) {
    final v = json[key];
    if (v == null) return null;
    if (v is! String) {
      throw FormatException('$where: "$key" must be a string.');
    }
    if (v.isEmpty) {
      throw FormatException('$where: "$key" must not be empty.');
    }
    return v;
  }

  static String? _readOneOf(
    Map<String, dynamic> json, {
    required String key,
    required Set<String> allowed,
    required String where,
  }) {
    final v = _readString(json, key: key, where: where);
    if (v == null) return null;
    if (!allowed.contains(v)) {
      throw FormatException(
        '$where: "$key" must be one of ${allowed.join(", ")} (was "$v").',
      );
    }
    return v;
  }

  static bool? _readBool(
    Map<String, dynamic> json, {
    required String key,
    required String where,
  }) {
    final v = json[key];
    if (v == null) return null;
    if (v is! bool) {
      throw FormatException('$where: "$key" must be a boolean.');
    }
    return v;
  }
}
