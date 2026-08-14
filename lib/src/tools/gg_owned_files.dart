// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_lang/gg_lang.dart' as gg_lang;

import 'package:gg_one_core/src/tools/pubspec_overrides_backup.dart';

// #############################################################################
// The files a »#gg: « commit may legitimately contain.
//
// One source of truth for both directions: the system-commit helper uses it to
// decide what to *write* into a bookkeeping commit, `PublishSkipCheck` to
// decide whether a historic one only *contains* gg's own bookkeeping. Two
// lists would drift, and gg would end up writing commits its own skip check
// rejects.
//
// This lives in gg_one_core, not in gg_git: it is a statement about manifests,
// lock files and gg's own state files, not about git. gg_one_core is the
// lowest layer that sees both gg_git and gg_lang — and it already hosts the
// sibling list [GgState.ignoreFiles].

/// File names gg's bookkeeping owns, matched by their **basename**.
///
/// Basename rather than full path, because a repository may keep its package
/// in a subfolder and git then reports »packages/x/pubspec.yaml«. Matching the
/// whole path would silently stop recognizing exactly those.
///
/// The lock file names come from `gg_lang`, the same source
/// [GgState.ignoreFiles] uses — so the two lists cannot disagree about them.
final Set<String> ggOwnedFileNames = <String>{
  // Manifests gg rewrites while localizing/unlocalizing references and while
  // bumping the version.
  'pubspec.yaml',
  'pubspec_overrides.yaml',
  'package.json',
  // gg_localize_refs redirects pnpm-managed TypeScript deps through the
  // »overrides« of pnpm-workspace.yaml.
  'pnpm-workspace.yaml',
  // Written by the release step, never by hand in a bookkeeping commit.
  'CHANGELOG.md',
  ...gg_lang.allLockFileNames,
};

/// Files gg owns only at the repository root, matched by their **full**
/// repo-relative path.
///
/// gg writes exactly the top-level ones; a nested `.gitignore` belongs to the
/// user and must keep blocking a skip.
final Set<String> ggOwnedRootFiles = <String>{
  '.gitignore',
  '.gitattributes',
  // The state file of the days before it moved into `.gg/`.
  '.gg.json',
  // The gg_localize_refs backup of the days before it moved into `.gg/`.
  '.gg_localize_refs_backup.json',
  '.kidney_status',
  pubspecOverridesBackupPath,
  pnpmWorkspaceBackupPath,
};

/// The directory name that holds gg's own state — owned at any depth.
const String ggDirName = '.gg';

/// Generated files whose name derives from the package name, so no fixed list
/// can hold them.
///
/// `gg_version`'s `WriteVersionFile` writes `lib/src/<slug>_version.dart` plus
/// the mirror test `test/<slug>_version_test.dart` for Dart and Flutter, and
/// `src/<slug>_version.ts` plus `test/<slug>_version.test.ts` for TypeScript.
/// They ride along every version bump; without them here, every commit that
/// bumps a version would look as if it had swallowed user work.
final List<RegExp> ggOwnedPathPatterns = <RegExp>[
  RegExp(r'(^|/)lib/src/[A-Za-z0-9_]+_version\.dart$'),
  RegExp(r'(^|/)test/[A-Za-z0-9_]+_version_test\.dart$'),
  RegExp(r'(^|/)src/[A-Za-z0-9_]+_version\.ts$'),
  RegExp(r'(^|/)test/[A-Za-z0-9_]+_version\.test\.ts$'),
];

// .............................................................................
/// Whether [repoRelativePath] — as git prints it, with forward slashes —
/// belongs to gg's own bookkeeping.
///
/// Everything undecidable answers false: a path that cannot be classified is
/// treated as the user's, so it blocks a skip rather than being swept away.
bool isGgOwnedPath(String repoRelativePath) {
  var path = repoRelativePath.trim();
  if (path.isEmpty) {
    return false;
  }

  // A path git had to quote (non-ASCII, special characters) does not name the
  // file as written here. Treat it as the user's rather than guessing.
  if (path.startsWith('"')) {
    return false;
  }

  if (path.startsWith('./')) {
    path = path.substring(2);
  }

  final segments = path.split('/');
  if (segments.contains(ggDirName)) {
    return true;
  }

  if (ggOwnedRootFiles.contains(path)) {
    return true;
  }

  if (ggOwnedFileNames.contains(segments.last)) {
    return true;
  }

  return ggOwnedPathPatterns.any((pattern) => pattern.hasMatch(path));
}
