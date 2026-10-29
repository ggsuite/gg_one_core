// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_one_core/gg_one_core.dart';
import 'package:test/test.dart';

void main() {
  CommitMessage msg(String text) => CommitMessage.parse(text);

  group('commitSheetEntry()', () {
    test('starts with the ticket description without a config', () {
      final entry = commitSheetEntry(
        repo: 'a',
        config: null,
        description: 'Ticket desc\nDetail',
      );
      expect(entry.repo, 'a');
      expect(entry.commitMessage?.text, 'Ticket desc\n\nDetail');
      expect(entry.mergeMessage, 'Ticket desc\nDetail');
      expect(entry.versionIncrement, isNull);
    });

    test('starts with what the config records', () {
      final entry = commitSheetEntry(
        repo: 'a',
        config: RepoPublishConfig(
          nextCommitMessage: msg('Proposed'),
          mergeMessage: 'Recorded',
        ),
        description: 'Ticket desc',
      );
      expect(entry.commitMessage?.text, 'Proposed');
      expect(entry.mergeMessage, 'Recorded');
    });

    test('names the repo when there is no description', () {
      final entry = commitSheetEntry(
        repo: 'a',
        config: RepoPublishConfig(),
        description: '  ',
      );
      expect(entry.commitMessage?.firstLine, isEmpty);
      expect(entry.mergeMessage, 'Publish a');
    });
  });

  group('withCommitAnswers()', () {
    final config = RepoPublishConfig(
      mergeMessage: 'Old merge',
      nextCommitMessage: msg('Proposed'),
    );
    final shown = MessageSheetEntry(
      repo: 'a',
      commitMessage: msg('Proposed'),
      mergeMessage: 'Old merge',
    );
    MessageSheetEntry edit({String? commit, String? merge}) =>
        MessageSheetEntry(
          repo: 'a',
          commitMessage: msg(commit ?? 'Proposed'),
          mergeMessage: merge ?? 'Old merge',
        );

    test('returns the config itself when there is nothing to record', () {
      expect(config.withCommitAnswers(), same(config));
      expect(
        config.withCommitAnswers(shown: shown, edited: shown),
        same(config),
      );
      // An emptied first line is no message.
      expect(
        config.withCommitAnswers(
          committed: msg(''),
          shown: shown,
          edited: edit(commit: ''),
        ),
        same(config),
      );
    });

    test('records the commit and keeps the proposal', () {
      final result = config.withCommitAnswers(
        committed: msg('Edited'),
        shown: shown,
        edited: edit(commit: 'Edited'),
      );
      expect(result.commits.single.firstLine, 'Edited');
      expect(result.nextCommitMessage?.firstLine, 'Proposed');
      expect(result.mergeMessage, 'Old merge');
    });

    test('records a changed merge message only', () {
      final changed = config.withCommitAnswers(
        shown: shown,
        edited: edit(merge: ' New merge '),
      );
      expect(changed.mergeMessage, 'New merge');

      final unchanged = RepoPublishConfig().withCommitAnswers(
        shown: shown,
        edited: edit(merge: 'Old merge '),
      );
      expect(unchanged.mergeMessage, isNull);
    });

    test('takes every merge message as changed without a shown entry', () {
      expect(
        RepoPublishConfig().withCommitAnswers(edited: edit()).mergeMessage,
        'Old merge',
      );
    });

    test('skips the merge message when it may not be written', () {
      final result = config.withCommitAnswers(
        committed: msg('Done'),
        shown: shown,
        edited: edit(merge: 'New merge'),
        withMergeMessage: false,
      );
      expect(result.mergeMessage, 'Old merge');
      expect(result.commits.single.firstLine, 'Done');
    });

    test('keeps an edited commit message that was not committed', () {
      final result = config.withCommitAnswers(
        shown: shown,
        edited: edit(commit: 'Edited\nDetail'),
      );
      expect(result.nextCommitMessage?.text, 'Edited\n\nDetail');
      expect(result.commits, isEmpty);
    });
  });
}
