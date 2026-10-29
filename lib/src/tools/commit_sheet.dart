// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'commit_message.dart';
import 'message_sheet.dart';
import 'repo_publish_config.dart';

// .............................................................................
/// The entry `gg do commit` shows for [repo] on a [MessageSheet].
///
/// The commit message starts with the proposal of [config], else the ticket
/// [description]. The merge message starts with the one [config] recorded,
/// else the description, else `Publish <repo>`.
MessageSheetEntry commitSheetEntry({
  required String repo,
  required RepoPublishConfig? config,
  required String description,
}) {
  final mergeMessage = config?.mergeMessage ?? description.trim();
  return MessageSheetEntry(
    repo: repo,
    commitMessage:
        config?.nextCommitMessage ?? CommitMessage.parse(description),
    mergeMessage: mergeMessage.isEmpty ? 'Publish $repo' : mergeMessage,
  );
}

// .............................................................................
/// Records what `gg do commit` learned about a repository.
extension CommitSheetAnswers on RepoPublishConfig {
  /// This config with the answers `gg do commit` got for its repository — or
  /// this very config when there is nothing new to record.
  ///
  /// [committed] is the message a commit was just made with. It joins the
  /// [RepoPublishConfig.commits]; an empty message is never recorded.
  ///
  /// [shown] and [edited] are the repository's entry as it was put on the
  /// [MessageSheet] and as the user saved it. Only what the user changed is
  /// kept, so a default that was merely confirmed does not freeze — a later
  /// change of the ticket description still reaches `gg do review`:
  ///
  /// - a changed merge message becomes [RepoPublishConfig.mergeMessage],
  ///   unless [withMergeMessage] is false;
  /// - a changed commit message that was not committed — the commit failed —
  ///   becomes [RepoPublishConfig.nextCommitMessage], so the next run offers
  ///   it again. A committed one leaves the proposal alone: it is the
  ///   standing proposal the AI keeps up to date, not a buffer.
  RepoPublishConfig withCommitAnswers({
    CommitMessage? committed,
    MessageSheetEntry? shown,
    MessageSheetEntry? edited,
    bool withMergeMessage = true,
  }) {
    var result = this;
    if (committed != null && committed.firstLine.trim().isNotEmpty) {
      result = result.withCommitted(committed);
    }

    final mergeMessage = edited?.mergeMessage?.trim() ?? '';
    if (withMergeMessage &&
        mergeMessage.isNotEmpty &&
        mergeMessage != shown?.mergeMessage?.trim()) {
      result = result.copyWith(mergeMessage: mergeMessage);
    }

    final commitMessage = edited?.commitMessage;
    if (committed == null &&
        commitMessage != null &&
        commitMessage.firstLine.trim().isNotEmpty &&
        commitMessage.text != shown?.commitMessage?.text) {
      result = result.copyWith(nextCommitMessage: commitMessage);
    }
    return result;
  }
}
