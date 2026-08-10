// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:path/path.dart';

import '../commands/check/no_pubspec_overrides.dart';

/// Where a publish keeps the `pubspec_overrides.yaml` it has to delete.
///
/// The file lives inside `.gg/`, which is gitignored (`.gg/*`), so the backup
/// never reaches a release, a merge or the working-tree hash — while the
/// overrides file itself is tracked, because it travels with shared ticket
/// workspaces.
const String pubspecOverridesBackupPath = '.gg/pubspec_overrides_backup.yaml';

/// Where a publish keeps the `pnpm-workspace.yaml` of a TypeScript repo.
///
/// The TypeScript twin of [pubspecOverridesBackupPath]: gg_localize_refs
/// redirects pnpm-managed dependencies through the `overrides` section of
/// `pnpm-workspace.yaml`, and unlocalizing removes that section (or the whole
/// file, when gg created it). The backup preserves the exact pre-publish
/// state — including the user's pnpm settings — for the restore after the
/// merge.
const String pnpmWorkspaceBackupPath = '.gg/pnpm_workspace_backup.yaml';

/// The name of pnpm's per-repository settings file.
const String _pnpmWorkspaceFileName = 'pnpm-workspace.yaml';

/// Saves the workspace wiring files of [directory] so they can be restored
/// after the publish: `pubspec_overrides.yaml` to
/// [pubspecOverridesBackupPath] and `pnpm-workspace.yaml` to
/// [pnpmWorkspaceBackupPath].
///
/// Publishing removes the localized redirections — the package must resolve
/// against the registry, not against the developer's working copies. Without
/// a backup the repository loses its workspace wiring the moment it is
/// published; with it, the publish flow puts the files back once the release
/// is through and the feature branch is checked out again, so the repo
/// stays workable.
///
/// An existing backup is overwritten — the current files are the truth.
/// Returns whether at least one backup was written; without the files there
/// is nothing to save and the previous backups (if any) stay untouched.
bool backupPubspecOverrides(Directory directory) {
  final savedOverrides = _backup(
    directory,
    NoPubspecOverrides.fileName,
    pubspecOverridesBackupPath,
  );
  final savedPnpm = _backup(
    directory,
    _pnpmWorkspaceFileName,
    pnpmWorkspaceBackupPath,
  );
  return savedOverrides || savedPnpm;
}

/// Restores the workspace wiring files of [directory] from their backups and
/// deletes the backups.
///
/// The counterpart of [backupPubspecOverrides]: once the published state is
/// merged into the main branch and the feature branch is checked out again,
/// the overrides return and the repository resolves its dependencies against
/// the sibling checkouts of the ticket like before the publish.
///
/// A file that already exists is overwritten — the backup holds the
/// pre-publish truth. Returns whether at least one backup was restored.
bool restorePubspecOverrides(Directory directory) {
  final restoredOverrides = _restore(
    directory,
    pubspecOverridesBackupPath,
    NoPubspecOverrides.fileName,
  );
  final restoredPnpm = _restore(
    directory,
    pnpmWorkspaceBackupPath,
    _pnpmWorkspaceFileName,
  );
  return restoredOverrides || restoredPnpm;
}

/// Copies `<directory>/<fileName>` to `<directory>/<backupPath>`.
/// Returns whether the file existed and was saved.
bool _backup(Directory directory, String fileName, String backupPath) {
  final file = File(join(directory.path, fileName));
  if (!file.existsSync()) {
    return false;
  }

  final backup = File(join(directory.path, backupPath));
  backup.parent.createSync(recursive: true);
  file.copySync(backup.path);
  return true;
}

/// Restores `<directory>/<fileName>` from `<directory>/<backupPath>` and
/// deletes the backup. Returns whether a backup existed and was restored.
bool _restore(Directory directory, String backupPath, String fileName) {
  final backup = File(join(directory.path, backupPath));
  if (!backup.existsSync()) {
    return false;
  }

  final file = File(join(directory.path, fileName));
  backup.copySync(file.path);
  backup.deleteSync();
  return true;
}
