// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_git/gg_git.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_version/gg_version.dart';
import 'package:path/path.dart';
import 'package:pub_semver/pub_semver.dart';

import '../../tools/ensure_publish_config_ignored.dart';
import '../../tools/prompts.dart';
import '../../tools/publish_config.dart';
import '../../tools/terminal_guard.dart';
import '../../tools/version_selector.dart';

/// Typedef for editing the merge message interactively.
typedef EditMessage = Future<String?> Function(String initialMessage);

/// Typedef for confirming feature branch deletion.
typedef ConfirmDeleteFeatureBranch = bool Function(String branchName);

/// Interactively builds the `.gg/gg-publish.json` publish configuration for
/// the current repository: version increment (patch/minor/major) plus merge
/// message. `gg do publish` runs this automatically when it is started
/// without a configuration, so every interactive decision is made up front —
/// the same file then collects the per-step publish progress and is removed
/// after a fully successful publish.
/// Given on the command line, `--message` and `--delete-remote-branch` skip
/// the corresponding interactive prompt. `--merge-only` configures a
/// `gg do publish --merge-only` run: no version increment is asked for,
/// because a merge releases nothing.
class DoConfigurePublish extends DirCommand<void> {
  /// Constructor
  DoConfigurePublish({
    required super.ggLog,
    super.name = 'configure-publish',
    super.description = 'Create the publish configuration of the repo',
    VersionSelector? versionSelector,
    FromPubspec? fromPubspec,
    EditMessage? editMessage,
    ConfirmDeleteFeatureBranch? confirmDeleteFeatureBranch,
    LocalBranch? localBranch,
    EnsurePublishConfigIgnored? ensureIgnored,
    // coverage:ignore-start
  }) : _versionSelector = versionSelector ?? VersionSelector(),
       _fromPubspec = fromPubspec ?? FromPubspec(ggLog: ggLog),
       _editMessage = editMessage ?? _defaultEditMessage,
       _confirmDeleteFeatureBranch =
           confirmDeleteFeatureBranch ?? defaultConfirmDeleteFeatureBranch,
       _localBranch = localBranch ?? LocalBranch(ggLog: ggLog),
       _ensureIgnored =
           ensureIgnored ?? EnsurePublishConfigIgnored(ggLog: ggLog) {
    // coverage:ignore-end
    _addArgs();
  }

  final VersionSelector _versionSelector;
  final FromPubspec _fromPubspec;
  final EditMessage _editMessage;
  final ConfirmDeleteFeatureBranch _confirmDeleteFeatureBranch;
  final LocalBranch _localBranch;
  final EnsurePublishConfigIgnored _ensureIgnored;

  /// Returns the `.gg/gg-publish.json` file for [repoDir].
  ///
  /// The files inside `.gg` are no longer hidden. A publish that was
  /// interrupted before that change left its progress under the old
  /// `.gg/.gg-publish.json`; renaming it here keeps `--continue` working
  /// across the upgrade instead of reporting "nothing to continue".
  static File configFileFor(Directory repoDir) {
    final file = File(join(repoDir.path, '.gg', 'gg-publish.json'));
    final legacy = File(join(repoDir.path, '.gg', '.gg-publish.json'));

    if (!file.existsSync() && legacy.existsSync()) {
      legacy.renameSync(file.path);
    }

    return file;
  }

  @override
  Future<void> get({required Directory directory, required GgLog ggLog}) async {
    final deleteWasParsed =
        argResults?.wasParsed('delete-feature-branch') ?? false;
    await configure(
      directory: directory,
      ggLog: ggLog,
      mergeMessage: argResults?['message'] as String?,
      deleteFeatureBranch: deleteWasParsed
          ? (argResults?['delete-feature-branch'] as bool?)
          : null,
      mergeOnly: argResults?['merge-only'] as bool? ?? false,
    );
  }

  /// Builds the publish configuration for [directory], writes it to
  /// `<repo>/.gg/gg-publish.json` and returns it. Before the file is
  /// written, `.gg/gg-publish.json` is added to the repository's
  /// `.gitignore` (and that change committed) so the runtime file never
  /// shows up as an untracked file.
  ///
  /// [versionIncrement], [mergeMessage] and [deleteFeatureBranch] are presets
  /// (e.g. from `-m`/`--delete-feature-branch` or a programmatic caller): a
  /// preset value is used as-is and its prompt is skipped. A missing merge
  /// message is asked for with the `ticket.json` description as the initial
  /// value; an empty answer falls back to the description and finally to
  /// `Publish <dirname>`, so it is never empty. The delete-feature-branch
  /// decision is asked HERE — before the publish starts — so no interactive
  /// prompt sits between the irreversible publish steps anymore.
  ///
  /// [mergeOnly] configures a `gg do publish --merge-only` run: it releases
  /// nothing, so no version increment is asked for and none is stored.
  Future<PublishConfig> configure({
    required Directory directory,
    required GgLog ggLog,
    String? versionIncrement,
    String? mergeMessage,
    bool? deleteFeatureBranch,
    bool mergeOnly = false,
  }) async {
    await check(directory: directory);

    // Never clobber the progress of an unfinished publish — rewriting the
    // file would silently discard `done_steps`, and the next publish would
    // re-run steps that already happened (e.g. bump and release a second
    // version on top of the already-published one).
    final file = configFileFor(directory);
    if (file.existsSync()) {
      final existing = PublishConfig.load(
        configArg: file.path,
        fallbackDir: directory.path,
      );
      if (existing.hasStepProgress) {
        throw Exception(
          cError(
            unfinishedPublishMessage(path: file.path, command: 'gg do publish'),
          ),
        );
      }
    }

    await _ensureIgnored.ensure(directory: directory);

    // A merge-only run releases nothing: no version bump, no changelog
    // heading, no tag. Asking for an increment would offer a version that is
    // never created, so the prompt is skipped and no increment is stored.
    final increment = mergeOnly
        ? null
        : versionIncrement ??
              (await _versionSelector.selectIncrement(
                currentVersion: await _currentVersion(directory),
              )).name;

    var message = mergeMessage?.trim() ?? '';
    if (message.isEmpty) {
      final ticketDescription = _readTicketDescription(directory) ?? '';
      message = (await _editMessage(ticketDescription) ?? '').trim();
      if (message.isEmpty) {
        message = ticketDescription.trim();
      }
      if (message.isEmpty) {
        message = 'Publish ${basename(directory.path)}';
      }
    }

    final delete =
        deleteFeatureBranch ??
        _confirmDeleteFeatureBranch(
          await _localBranch.get(directory: directory, ggLog: <String>[].add),
        );

    final config = PublishConfig(
      versionIncrement: increment,
      mergeMessage: message,
      deleteFeatureBranch: delete,
    );
    await config.save(file: file);
    // ggLog(cDetail('Wrote publish configuration to ${file.path}'));
    return config;
  }

  /// Reads the version used as the baseline for the increment preview.
  /// Falls back to the `package.json` version (TypeScript), then to the
  /// latest git version tag (projects without a manifest) and finally to
  /// 0.0.0 — only the chosen increment is stored, so the baseline is
  /// preview-only.
  Future<Version> _currentVersion(Directory directory) async {
    try {
      return await _fromPubspec.fromDirectory(directory: directory);
    } catch (_) {
      try {
        final packageJson = File(join(directory.path, 'package.json'));
        final decoded = jsonDecode(packageJson.readAsStringSync());
        return Version.parse(
          (decoded as Map<String, dynamic>)['version'].toString(),
        );
      } catch (_) {
        try {
          final latest = await FromGit(
            ggLog: <String>[].add,
          ).latest(ggLog: <String>[].add, directory: directory);
          return latest ?? Version(0, 0, 0);
        } catch (_) {
          // Defensive: configure always runs inside a git repo, so the tag
          // lookup cannot fail there — but a preview value must never crash.
          return Version(0, 0, 0); // coverage:ignore-line
        }
      }
    }
  }

  /// Reads the optional description from the `ticket.json` file, used as the
  /// default merge message. Malformed or hand-edited files must not crash
  /// the configuration.
  String? _readTicketDescription(Directory directory) {
    final ticketFile = File(join(directory.path, 'ticket.json'));
    if (!ticketFile.existsSync()) {
      return null;
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(ticketFile.readAsStringSync());
    } catch (_) {
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

  /// Opens an interactive editor for the merge message.
  // coverage:ignore-start
  static Future<String?> _defaultEditMessage(String initialMessage) async {
    throwWhenNotATerminal(
      'the merge message prompt',
      'pass -m <message> or provide a .gg/gg-publish.json (--config)',
    );
    return GgPrompts.current.input(
      prompt: 'Edit merge message:',
      defaultValue: initialMessage,
      initialText: initialMessage,
      asMessageEditor: true,
    );
  }

  /// Asks whether the feature branch should be deleted after publishing.
  /// Shared default for `configure-publish` and `do publish`.
  static bool defaultConfirmDeleteFeatureBranch(String branchName) {
    throwWhenNotATerminal(
      'the delete-feature-branch prompt',
      'pass --delete-feature-branch / --no-delete-feature-branch or set '
          'delete_feature_branch in .gg/gg-publish.json',
    );
    final selection = GgPrompts.current.select(
      prompt: 'Delete feature branch $branchName on origin?',
      options: const <String>['Yes', 'No'],
    );

    return selection == 0;
  }
  // coverage:ignore-end

  void _addArgs() {
    argParser.addOption(
      'message',
      abbr: 'm',
      help: 'The merge message to write into the config',
    );
    argParser.addFlag(
      'merge-only',
      help: 'Configure a merge-only run, without increments',
      defaultsTo: false,
      negatable: false,
    );
    argParser.addFlag(
      'delete-feature-branch',
      help: 'Delete the feature branch on origin afterwards',
      defaultsTo: true,
      negatable: true,
    );
  }
}

/// Mock for [DoConfigurePublish].
class MockDoConfigurePublish extends MockDirCommand<void>
    implements DoConfigurePublish {}
