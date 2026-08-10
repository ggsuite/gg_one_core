// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_publish/gg_publish.dart';
import 'package:path/path.dart';
import 'package:test/test.dart';

void main() {
  late Directory d;

  setUp(() async {
    // The legacy split keys per-repo overrides by the folder name, so the
    // temp directory must carry the repository's name.
    d = Directory(
      join(
        (await Directory.systemTemp.createTemp('publish_files_')).path,
        'gg_one_core',
      ),
    )..createSync(recursive: true);
  });

  tearDown(() async {
    await d.parent.delete(recursive: true);
  });

  void writeLegacy(String content) =>
      File(join(d.path, '.gg', 'gg-publish.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(content);

  group('loadRepoPublishFiles()', () {
    test('returns empty halves when nothing was recorded', () {
      final files = loadRepoPublishFiles(d);
      expect(files.config.mergeMessage, isNull);
      expect(files.state.doneSteps, isEmpty);
    });

    test('reads the new files', () async {
      await RepoPublishConfig(
        mergeMessage: 'New',
        versionIncrement: VersionIncrement.minor,
      ).save(file: repoPublishConfigFile(d));
      await PublishState(doneSteps: ['merge']).save(file: publishStateFile(d));

      final files = loadRepoPublishFiles(d);
      expect(files.config.mergeMessage, 'New');
      expect(files.state.doneSteps, ['merge']);
    });

    test('fills the missing half when only one new file exists', () async {
      await RepoPublishConfig(
        mergeMessage: 'New',
      ).save(file: repoPublishConfigFile(d));

      final files = loadRepoPublishFiles(d);
      expect(files.config.mergeMessage, 'New');
      expect(files.state.doneSteps, isEmpty);
    });

    test('fills the missing half when only the state file exists', () async {
      await PublishState(doneSteps: ['merge']).save(file: publishStateFile(d));

      final files = loadRepoPublishFiles(d);
      expect(files.config.mergeMessage, isNull);
      expect(files.state.doneSteps, ['merge']);
    });

    test('falls back to a legacy gg-publish.json', () {
      writeLegacy('''
{
  "version_increment": "major",
  "merge_message": "Legacy",
  "branch": "feature",
  "pr": true,
  "channel": "rc",
  "delete_ticket": true,
  "delete_feature_branch": false,
  "done_steps": ["prepare_version"]
}
''');

      final files = loadRepoPublishFiles(d);
      expect(files.config.mergeMessage, 'Legacy');
      expect(files.config.versionIncrement, VersionIncrement.major);
      expect(files.state.doneSteps, ['prepare_version']);
      expect(files.state.branch, 'feature');
      expect(files.state.pr, isTrue);
      expect(files.state.channel, 'rc');
      expect(files.state.deleteTicket, isTrue);
      expect(files.state.deleteFeatureBranch, isFalse);
    });

    test('prefers a repo override over the legacy top-level default', () {
      writeLegacy('''
{
  "version_increment": "patch",
  "merge_message": "Top",
  "repos": {
    "gg_one_core": {
      "version_increment": "minor",
      "merge_message": "Mine",
      "channel": "rc",
      "status": "published"
    }
  }
}
''');

      final files = loadRepoPublishFiles(d);
      expect(files.config.mergeMessage, 'Mine');
      expect(files.config.versionIncrement, VersionIncrement.minor);
      expect(files.state.channel, 'rc');
      expect(files.state.status, 'published');
    });

    test('a legacy file without an increment yields none', () {
      writeLegacy('{"merge_message":"Legacy"}');
      expect(loadRepoPublishFiles(d).config.versionIncrement, isNull);
    });

    test('the new files win over a legacy one', () async {
      writeLegacy('{"merge_message":"Legacy"}');
      await RepoPublishConfig(
        mergeMessage: 'New',
      ).save(file: repoPublishConfigFile(d));

      expect(loadRepoPublishFiles(d).config.mergeMessage, 'New');
    });
  });

  group('legacyPublishConfigFile()', () {
    test('names <repo>/.gg/gg-publish.json', () {
      expect(
        legacyPublishConfigFile(d).path,
        join(d.path, '.gg', 'gg-publish.json'),
      );
    });

    test('renames the even older hidden .gg-publish.json', () {
      // A publish interrupted before the files inside .gg were unhidden left
      // its progress under the dot-prefixed name — --continue has to find it.
      final hidden = File(join(d.path, '.gg', '.gg-publish.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"merge_message":"Legacy"}');

      final file = legacyPublishConfigFile(d);

      expect(file.path, join(d.path, '.gg', 'gg-publish.json'));
      expect(file.readAsStringSync(), '{"merge_message":"Legacy"}');
      expect(hidden.existsSync(), isFalse);
      // And the migrated file is what the loader answers from.
      expect(loadRepoPublishFiles(d).config.mergeMessage, 'Legacy');
    });

    test('keeps the unhidden file when both exist', () {
      File(join(d.path, '.gg', '.gg-publish.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"merge_message":"hidden"}');
      File(join(d.path, '.gg', 'gg-publish.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"merge_message":"current"}');

      expect(
        legacyPublishConfigFile(d).readAsStringSync(),
        '{"merge_message":"current"}',
      );
    });
  });

  test('emptyRepoPublishFiles has empty halves', () {
    expect(emptyRepoPublishFiles.config.commits, isEmpty);
    expect(emptyRepoPublishFiles.state.doneSteps, isEmpty);
  });
}
