// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_publish/gg_publish.dart'
    show ReleaseChannel, VersionIncrement;
import 'package:path/path.dart' as p;

/// Allowed values for `version_increment` in a `.gg-publish.json` file.
const Set<String> allowedVersionIncrements = {'patch', 'minor', 'major'};

/// Allowed values for `channel` in a `.gg-publish.json` file. `stable` (the
/// default when the field is missing) is a regular release; `rc` publishes
/// the next `X.Y.Z-rc.N` prerelease of the target version.
const Set<String> allowedReleaseChannels = {'stable', 'rc'};

/// Allowed values for the per-repo `status` progress marker written into a
/// `.gg-publish.json` file while `gg_multi do publish` runs. `published` means
/// the repo finished publishing and may be skipped on a `--continue` re-run;
/// `skipped` means the run decided the repo does not need a release (no
/// breaking dependency bump and no manual changes) and left it untouched;
/// `pending`/`failed` mean it still has to be (re-)published.
const Set<String> allowedPublishStatuses = {
  'pending',
  'published',
  'failed',
  'skipped',
};

/// Allowed entries of the repo-level `done_steps` progress list written into
/// `<repo>/.gg/gg-publish.json` while `gg do publish` runs. Steps not listed
/// here (the feature/main/tag pushes and the feature-branch deletion) are
/// idempotent and always re-run on a `--continue`, so they are not tracked.
const Set<String> allowedPublishSteps = {
  'prepare_version',
  'publish_registry',
  'merge',
  'tag',
};

/// The message shown when a leftover `.gg-publish.json` still carries the
/// progress of an unfinished run.
///
/// [command] is the command the caller offers — `gg do publish` for a single
/// repo, `gg do publish --merge-only` for a merge-only ticket run. Written as
/// three short lines: what is in the way, and the two ways out. Four callers
/// used to carry their own 130-character copy of this.
String unfinishedPublishMessage({
  required String path,
  required String command,
}) => [
  cError('Unfinished publish in $path'),
  cAction('  Continue:') + cCmd('$command --continue'),
  cAction('  Restart: ') + cCmd('$command --restart'),
].join('\n');

/// The message shown when `--continue` is combined with a flag that would
/// discard the very progress it resumes.
final String continueConflictMessage = [
  cError(
    '"--continue" cannot be combined with ${cCmd("--config")} '
    'or ${cCmd("--restart.")}',
  ),
  cAction('Resume with ${cCmd("--continue")} alone, '),
  cAction('or start a fresh run without it.'),
].join('\n');

/// Returned by [PublishConfig.forRepo] (and used directly in single-repo
/// scenarios). Both fields are present and validated when this is constructed
/// — the caller may treat them as authoritative inputs to a publish run.
class ResolvedPublishValues {
  /// Creates a resolved set of publish values.
  const ResolvedPublishValues({
    required this.versionIncrement,
    required this.mergeMessage,
  });

  /// One of `patch`, `minor`, `major` — null in a merge-only run, which
  /// creates no release and therefore needs no increment.
  final String? versionIncrement;

  /// The merge commit message used for the final merge step.
  final String mergeMessage;
}

/// In-memory representation of a `.gg-publish.json` config file.
/// Top-level `version_increment` / `merge_message` are defaults.
/// Entries under `repos.<name>` override the defaults per repo.
class PublishConfig {
  /// Constructor (used by [load] and tests).
  PublishConfig({
    this.versionIncrement,
    this.mergeMessage,
    this.channel,
    this.deleteTicket,
    this.deleteFeatureBranch,
    this.pr,
    this.branch,
    Map<String, RepoOverride>? repos,
    List<String>? doneSteps,
  }) : repos = repos ?? const {},
       doneSteps = doneSteps ?? const [];

  /// Default `version_increment`; null when only per-repo overrides exist.
  final String? versionIncrement;

  /// Default `merge_message`; null when only per-repo overrides exist.
  final String? mergeMessage;

  /// Default release `channel` (one of [allowedReleaseChannels]); null means
  /// `stable`.
  final String? channel;

  /// Top-level `delete_ticket`; bypasses the interactive prompt when set.
  final bool? deleteTicket;

  /// Top-level `delete_feature_branch` (single-repo): bypasses the
  /// interactive delete-feature-branch prompt when set, so a `--config` /
  /// `.gg/gg-publish.json` driven publish is fully headless.
  final bool? deleteFeatureBranch;

  /// Top-level `pr`: whether the final merge goes through an auto-merge pull
  /// request (true, the default) or a local merge + direct push (`--no-pr`).
  /// Persisted so a `--continue` resumes in the same mode.
  final bool? pr;

  /// Per-repo overrides keyed by repository name.
  final Map<String, RepoOverride> repos;

  /// Repo-level progress: the publish steps (see [allowedPublishSteps]) that
  /// already completed, in completion order. Written by `gg do publish` while
  /// it runs; empty for a plain configuration file.
  final List<String> doneSteps;

  /// Repo-level runtime marker: the feature branch the publish started on.
  /// A resumed run may find HEAD on the default branch (the merge already
  /// happened), so the branch to delete must not be re-read from HEAD.
  final String? branch;

  /// Resolves the effective publish values for a single-repo run. Throws a
  /// [FormatException] when `version_increment` or `merge_message` is missing
  /// at the top level.
  ResolvedPublishValues resolveSingle({
    required String configPath,
    bool requireVersionIncrement = true,
  }) {
    final increment = versionIncrement;
    final message = mergeMessage;
    final missing = <String>[];
    if (increment == null && requireVersionIncrement) {
      missing.add('version_increment');
    }
    if (message == null) missing.add('merge_message');
    if (missing.isNotEmpty) {
      throw FormatException(
        'Config $configPath is missing required field(s): '
        '${missing.join(", ")}',
      );
    }
    return ResolvedPublishValues(
      versionIncrement: increment,
      mergeMessage: message!,
    );
  }

  /// Resolves the effective publish values for [repoName] in a multi-repo run.
  /// Per-repo overrides take precedence over top-level defaults. Throws a
  /// [FormatException] when neither source supplies a value for either field.
  ResolvedPublishValues forRepo({
    required String repoName,
    required String configPath,
    bool requireVersionIncrement = true,
  }) {
    final override = repos[repoName];
    final increment = override?.versionIncrement ?? versionIncrement;
    final message = override?.mergeMessage ?? mergeMessage;
    final missing = <String>[];
    if (increment == null && requireVersionIncrement) {
      missing.add('version_increment');
    }
    if (message == null) missing.add('merge_message');
    if (missing.isNotEmpty) {
      throw FormatException(
        'Config $configPath is missing required field(s) for $repoName: '
        '${missing.join(", ")} (neither top-level nor repos.$repoName).',
      );
    }
    return ResolvedPublishValues(
      versionIncrement: increment,
      mergeMessage: message!,
    );
  }

  /// Loads a [PublishConfig] from [configArg], falling back to
  /// `<fallbackDir>/<configArg>`. Throws [FileSystemException] when no file
  /// is found and [FormatException] on invalid JSON / field types.
  factory PublishConfig.load({
    required String configArg,
    required String fallbackDir,
  }) {
    final candidates = <String>[configArg, p.join(fallbackDir, configArg)];
    File? found;
    for (final candidate in candidates) {
      final file = File(candidate);
      if (file.existsSync()) {
        found = file;
        break;
      }
    }
    if (found == null) {
      throw FileSystemException(
        'Could not find publish config. Tried: '
        '${candidates.join(", ")}',
        configArg,
      );
    }

    final raw = found.readAsStringSync();
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw FormatException(
        'Publish config ${found.path} is not valid JSON: ${e.message}',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw FormatException(
        'Publish config ${found.path} must contain a JSON object at the '
        'top level.',
      );
    }

    final increment = _readIncrement(
      decoded,
      key: 'version_increment',
      where: found.path,
    );
    final message = _readString(
      decoded,
      key: 'merge_message',
      where: found.path,
    );
    final channel = _readChannel(decoded, key: 'channel', where: found.path);
    final deleteTicket = _readBool(
      decoded,
      key: 'delete_ticket',
      where: found.path,
    );
    final deleteFeatureBranch = _readBool(
      decoded,
      key: 'delete_feature_branch',
      where: found.path,
    );
    final pr = _readBool(decoded, key: 'pr', where: found.path);

    final repos = <String, RepoOverride>{};
    final rawRepos = decoded['repos'];
    if (rawRepos != null) {
      if (rawRepos is! Map<String, dynamic>) {
        throw FormatException(
          'Publish config ${found.path}: "repos" must be a JSON object.',
        );
      }
      for (final entry in rawRepos.entries) {
        final repoName = entry.key;
        final inner = entry.value;
        if (inner is! Map<String, dynamic>) {
          throw FormatException(
            'Publish config ${found.path}: repos.$repoName must be a JSON '
            'object.',
          );
        }
        repos[repoName] = RepoOverride(
          versionIncrement: _readIncrement(
            inner,
            key: 'version_increment',
            where: '${found.path} repos.$repoName',
          ),
          mergeMessage: _readString(
            inner,
            key: 'merge_message',
            where: '${found.path} repos.$repoName',
          ),
          channel: _readChannel(
            inner,
            key: 'channel',
            where: '${found.path} repos.$repoName',
          ),
          status: _readStatus(
            inner,
            key: 'status',
            where: '${found.path} repos.$repoName',
          ),
        );
      }
    }

    final doneSteps = _readSteps(decoded, key: 'done_steps', where: found.path);
    final branch = _readString(decoded, key: 'branch', where: found.path);

    return PublishConfig(
      versionIncrement: increment,
      mergeMessage: message,
      channel: channel,
      deleteTicket: deleteTicket,
      deleteFeatureBranch: deleteFeatureBranch,
      pr: pr,
      branch: branch,
      repos: repos,
      doneSteps: doneSteps,
    );
  }

  static List<String>? _readSteps(
    Map<String, dynamic> json, {
    required String key,
    required String where,
  }) {
    final v = json[key];
    if (v == null) return null;
    if (v is! List) {
      throw FormatException('$where: "$key" must be a list of strings.');
    }
    final steps = <String>[];
    for (final step in v) {
      if (step is! String || !allowedPublishSteps.contains(step)) {
        throw FormatException(
          '$where: "$key" entries must be one of '
          '${allowedPublishSteps.join(", ")} (was "$step").',
        );
      }
      if (!steps.contains(step)) steps.add(step);
    }
    return steps;
  }

  static bool? _readBool(
    Map<String, dynamic> json, {
    required String key,
    required String where,
  }) {
    if (!json.containsKey(key)) return null;
    final v = json[key];
    if (v == null) return null;
    if (v is! bool) {
      throw FormatException('$where: "$key" must be a boolean.');
    }
    return v;
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

  static String? _readIncrement(
    Map<String, dynamic> json, {
    required String key,
    required String where,
  }) {
    final v = _readString(json, key: key, where: where);
    if (v == null) return null;
    if (!allowedVersionIncrements.contains(v)) {
      throw FormatException(
        '$where: "$key" must be one of '
        '${allowedVersionIncrements.join(", ")} (was "$v").',
      );
    }
    return v;
  }

  static String? _readStatus(
    Map<String, dynamic> json, {
    required String key,
    required String where,
  }) {
    final v = _readString(json, key: key, where: where);
    if (v == null) return null;
    if (!allowedPublishStatuses.contains(v)) {
      throw FormatException(
        '$where: "$key" must be one of '
        '${allowedPublishStatuses.join(", ")} (was "$v").',
      );
    }
    return v;
  }

  static String? _readChannel(
    Map<String, dynamic> json, {
    required String key,
    required String where,
  }) {
    final v = _readString(json, key: key, where: where);
    if (v == null) return null;
    if (!allowedReleaseChannels.contains(v)) {
      throw FormatException(
        '$where: "$key" must be one of '
        '${allowedReleaseChannels.join(", ")} (was "$v").',
      );
    }
    return v;
  }

  /// This config as a JSON map. Null top-level fields and empty sections are
  /// omitted so the persisted `.gg-publish.json` stays minimal.
  Map<String, dynamic> toJson() => <String, dynamic>{
    if (versionIncrement != null) 'version_increment': versionIncrement,
    if (mergeMessage != null) 'merge_message': mergeMessage,
    if (channel != null) 'channel': channel,
    if (deleteTicket != null) 'delete_ticket': deleteTicket,
    if (deleteFeatureBranch != null)
      'delete_feature_branch': deleteFeatureBranch,
    if (pr != null) 'pr': pr,
    if (branch != null) 'branch': branch,
    if (doneSteps.isNotEmpty) 'done_steps': doneSteps,
    if (repos.isNotEmpty)
      'repos': <String, dynamic>{
        for (final entry in repos.entries) entry.key: entry.value.toJson(),
      },
  };

  /// This config pretty-printed as a two-space-indented JSON string.
  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Persists this config to [file], creating the parent directory (e.g. the
  /// ticket-level `.gg/`) when missing. Written as UTF-8 without a BOM.
  Future<void> save({required File file}) async {
    final parent = file.parent;
    if (!parent.existsSync()) {
      await parent.create(recursive: true);
    }
    await file.writeAsString('${toJsonString()}\n');
  }

  /// Returns the recorded publish [status] of [repoName], or null when the repo
  /// has no progress marker yet.
  String? statusForRepo(String repoName) => repos[repoName]?.status;

  /// Returns the effective release channel for [repoName]: the per-repo
  /// override, else the top-level default, else null (= `stable`).
  String? channelForRepo(String repoName) =>
      repos[repoName]?.channel ?? channel;

  /// Returns a copy of this config with [repoName]'s progress marker set to
  /// [status], preserving that repo's `version_increment` / `merge_message`.
  PublishConfig withRepoStatus(String repoName, String status) {
    final updated = Map<String, RepoOverride>.from(repos);
    final existing = updated[repoName];
    updated[repoName] = RepoOverride(
      versionIncrement: existing?.versionIncrement,
      mergeMessage: existing?.mergeMessage,
      channel: existing?.channel,
      status: status,
    );
    return PublishConfig(
      versionIncrement: versionIncrement,
      mergeMessage: mergeMessage,
      channel: channel,
      deleteTicket: deleteTicket,
      deleteFeatureBranch: deleteFeatureBranch,
      pr: pr,
      branch: branch,
      repos: updated,
      doneSteps: doneSteps,
    );
  }

  /// Whether the repo-level publish step [step] already completed.
  bool isStepDone(String step) => doneSteps.contains(step);

  /// Whether any repo-level publish step completed — i.e. this file is the
  /// leftover of an unfinished `gg do publish` run.
  bool get hasStepProgress => doneSteps.isNotEmpty;

  /// Returns a copy of this config with [step] appended to [doneSteps].
  /// Throws [ArgumentError] for step names outside [allowedPublishSteps];
  /// marking an already-done step is a no-op.
  PublishConfig withStepDone(String step) {
    if (!allowedPublishSteps.contains(step)) {
      throw ArgumentError.value(step, 'step', 'unknown publish step');
    }
    if (isStepDone(step)) return this;
    return PublishConfig(
      versionIncrement: versionIncrement,
      mergeMessage: mergeMessage,
      channel: channel,
      deleteTicket: deleteTicket,
      deleteFeatureBranch: deleteFeatureBranch,
      pr: pr,
      branch: branch,
      repos: repos,
      doneSteps: [...doneSteps, step],
    );
  }
}

/// Per-repo override block within a [PublishConfig]. The `version_increment`
/// and `merge_message` fields may be null, in which case the top-level default
/// applies. [status] is a runtime progress marker written during a publish run.
class RepoOverride {
  /// Constructor.
  RepoOverride({
    this.versionIncrement,
    this.mergeMessage,
    this.channel,
    this.status,
  });

  /// Per-repo `version_increment`, or null to inherit the top-level value.
  final String? versionIncrement;

  /// Per-repo `merge_message`, or null to inherit the top-level value.
  final String? mergeMessage;

  /// Per-repo release `channel`, or null to inherit the top-level value.
  final String? channel;

  /// Per-repo publish progress marker (one of [allowedPublishStatuses]), or
  /// null when the repo has not been touched by a publish run yet.
  final String? status;

  /// This override as a JSON map, omitting fields that are null so the written
  /// `.gg-publish.json` stays minimal.
  Map<String, dynamic> toJson() => <String, dynamic>{
    if (versionIncrement != null) 'version_increment': versionIncrement,
    if (mergeMessage != null) 'merge_message': mergeMessage,
    if (channel != null) 'channel': channel,
    if (status != null) 'status': status,
  };
}

/// Maps a version increment string to its [VersionIncrement] enum value.
/// Throws [ArgumentError] for unknown strings; validate earlier via
/// [allowedVersionIncrements].
VersionIncrement parseVersionIncrement(String increment) {
  switch (increment) {
    case 'patch':
      return VersionIncrement.patch;
    case 'minor':
      return VersionIncrement.minor;
    case 'major':
      return VersionIncrement.major;
  }
  throw ArgumentError.value(increment, 'increment', 'unknown increment');
}

/// Maps a release channel string to its [ReleaseChannel] enum value.
/// Throws [ArgumentError] for unknown strings; validate earlier via
/// [allowedReleaseChannels].
ReleaseChannel parseReleaseChannel(String channel) {
  switch (channel) {
    case 'stable':
      return ReleaseChannel.stable;
    case 'rc':
      return ReleaseChannel.rc;
  }
  throw ArgumentError.value(channel, 'channel', 'unknown channel');
}
