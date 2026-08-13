// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:path/path.dart' as p;

import 'publish_config.dart';
import 'publish_state.dart';
import 'repo_publish_config.dart';

/// The answers and the run progress of one repository, as read from disk.
typedef RepoPublishFiles = ({RepoPublishConfig config, PublishState state});

/// An empty pair — the answer for a repository nothing has been recorded for.
RepoPublishFiles get emptyRepoPublishFiles =>
    (config: RepoPublishConfig(), state: PublishState());

/// Reads the publish files of the repository at [repoDir].
///
/// Reading is layered, writing is not: `publish_config.json` and
/// `publish_state.json` win, and the legacy `gg-publish.json` of the same
/// repository fills in whichever of the two is missing. The two halves are
/// resolved **independently** — a run that has already written its answers
/// must still find the run state the legacy file carries. The legacy file is
/// left untouched: a `--continue` performed by an older gg must still find
/// it.
///
/// A repository nothing was ever recorded for yields empty halves rather
/// than null, so callers can read fields without a null dance.
RepoPublishFiles loadRepoPublishFiles(Directory repoDir) {
  final config = RepoPublishConfig.tryLoad(repoDir);
  final state = PublishState.tryLoad(repoDir);
  if (config != null && state != null) {
    return (config: config, state: state);
  }

  final legacy = legacyPublishConfigFile(repoDir);
  final fallback = legacy.existsSync()
      ? PublishConfig.load(
          configArg: legacy.path,
          fallbackDir: repoDir.path,
        ).legacySplit(p.basename(repoDir.path))
      : emptyRepoPublishFiles;

  return (config: config ?? fallback.config, state: state ?? fallback.state);
}

/// The legacy `<repo>/.gg/gg-publish.json`, migrating the even older
/// dot-prefixed `.gg/.gg-publish.json` name on the way.
///
/// The files inside `.gg` are no longer hidden. A publish interrupted before
/// that change left its progress under the old name; renaming it here keeps
/// `--continue` working across the upgrade instead of reporting "nothing to
/// continue".
File legacyPublishConfigFile(Directory repoDir) {
  final file = File(p.join(repoDir.path, '.gg', 'gg-publish.json'));
  final legacy = File(p.join(repoDir.path, '.gg', '.gg-publish.json'));

  if (!file.existsSync() && legacy.existsSync()) {
    legacy.renameSync(file.path);
  }

  return file;
}
