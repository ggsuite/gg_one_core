// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_publish/gg_publish.dart'
    show ReleaseChannel, VersionIncrement;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('PublishConfig', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('gg_publish_cfg_');
    });
    tearDown(() async => tmp.delete(recursive: true));

    Future<File> writeConfig(String name, String body) async {
      final f = File(p.join(tmp.path, name));
      await f.writeAsString(body);
      return f;
    }

    group('load() — path resolution', () {
      test('uses the as-given path first', () async {
        final f = await writeConfig('release.json', '''
{
  "version_increment": "patch",
  "merge_message": "from CWD"
}
''');
        final cfg = PublishConfig.load(
          configArg: f.path,
          fallbackDir: tmp.path,
        );
        expect(cfg.versionIncrement, 'patch');
        expect(cfg.mergeMessage, 'from CWD');
      });

      test('falls back to <fallbackDir>/<configArg>', () async {
        await writeConfig('release.json', '''
{
  "version_increment": "minor",
  "merge_message": "from fallback"
}
''');
        final cfg = PublishConfig.load(
          configArg: 'release.json',
          fallbackDir: tmp.path,
        );
        expect(cfg.versionIncrement, 'minor');
        expect(cfg.mergeMessage, 'from fallback');
      });

      test('throws FileSystemException when nothing is found', () {
        expect(
          () => PublishConfig.load(
            configArg: 'missing.json',
            fallbackDir: tmp.path,
          ),
          throwsA(isA<FileSystemException>()),
        );
      });
    });

    group('load() — schema validation', () {
      test('rejects non-JSON content', () async {
        await writeConfig('release.json', 'not a json');
        expect(
          () => PublishConfig.load(
            configArg: 'release.json',
            fallbackDir: tmp.path,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('not valid JSON'),
            ),
          ),
        );
      });

      test('rejects a non-object top-level value', () async {
        await writeConfig('release.json', '["array"]');
        expect(
          () => PublishConfig.load(
            configArg: 'release.json',
            fallbackDir: tmp.path,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('JSON object at the top level'),
            ),
          ),
        );
      });

      test(
        'rejects an unknown version_increment with an enumerating error',
        () async {
          await writeConfig('release.json', '''
{
  "version_increment": "huge",
  "merge_message": "x"
}
''');
          expect(
            () => PublishConfig.load(
              configArg: 'release.json',
              fallbackDir: tmp.path,
            ),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                allOf(
                  contains('version_increment'),
                  contains('patch'),
                  contains('minor'),
                  contains('major'),
                ),
              ),
            ),
          );
        },
      );

      test('rejects an empty merge_message', () async {
        await writeConfig('release.json', '''
{
  "version_increment": "patch",
  "merge_message": ""
}
''');
        expect(
          () => PublishConfig.load(
            configArg: 'release.json',
            fallbackDir: tmp.path,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"merge_message" must not be empty'),
            ),
          ),
        );
      });

      test('rejects a non-string merge_message', () async {
        await writeConfig('release.json', '''
{
  "version_increment": "patch",
  "merge_message": 42
}
''');
        expect(
          () => PublishConfig.load(
            configArg: 'release.json',
            fallbackDir: tmp.path,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"merge_message" must be a string'),
            ),
          ),
        );
      });

      test('rejects a non-object repos block', () async {
        await writeConfig('release.json', '''
{
  "version_increment": "patch",
  "merge_message": "x",
  "repos": []
}
''');
        expect(
          () => PublishConfig.load(
            configArg: 'release.json',
            fallbackDir: tmp.path,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"repos" must be a JSON object'),
            ),
          ),
        );
      });

      test('rejects a non-object repos.<name> entry', () async {
        await writeConfig('release.json', '''
{
  "version_increment": "patch",
  "merge_message": "x",
  "repos": { "foo": "bar" }
}
''');
        expect(
          () => PublishConfig.load(
            configArg: 'release.json',
            fallbackDir: tmp.path,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('repos.foo must be a JSON object'),
            ),
          ),
        );
      });

      test('parses valid repos.<name> entries - both fields, then each '
          'alone', () async {
        // Happy path of the `repos` loop in `load()`.
        await writeConfig('release.json', '''
{
  "version_increment": "patch",
  "merge_message": "top default",
  "repos": {
    "both_overrides": {
      "version_increment": "minor",
      "merge_message": "custom for both"
    },
    "only_version": {
      "version_increment": "major"
    },
    "only_message": {
      "merge_message": "custom message only"
    }
  }
}
''');
        final cfg = PublishConfig.load(
          configArg: 'release.json',
          fallbackDir: tmp.path,
        );
        expect(
          cfg.repos.keys,
          containsAll(<String>[
            'both_overrides',
            'only_version',
            'only_message',
          ]),
        );
        expect(cfg.repos['both_overrides']!.versionIncrement, 'minor');
        expect(cfg.repos['both_overrides']!.mergeMessage, 'custom for both');
        expect(cfg.repos['only_version']!.versionIncrement, 'major');
        expect(cfg.repos['only_version']!.mergeMessage, isNull);
        expect(cfg.repos['only_message']!.versionIncrement, isNull);
        expect(cfg.repos['only_message']!.mergeMessage, 'custom message only');
      });

      test('rejects an unknown version_increment in a repos entry', () async {
        await writeConfig('release.json', '''
{
  "version_increment": "patch",
  "merge_message": "x",
  "repos": {
    "foo": { "version_increment": "tiny" }
  }
}
''');
        expect(
          () => PublishConfig.load(
            configArg: 'release.json',
            fallbackDir: tmp.path,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('repos.foo'),
            ),
          ),
        );
      });

      test('parses delete_ticket=true at the top level', () async {
        await writeConfig('release.json', '''
{
  "version_increment": "patch",
  "merge_message": "x",
  "delete_ticket": true
}
''');
        final cfg = PublishConfig.load(
          configArg: 'release.json',
          fallbackDir: tmp.path,
        );
        expect(cfg.deleteTicket, isTrue);
      });

      test('parses delete_ticket=false at the top level', () async {
        await writeConfig('release.json', '''
{
  "version_increment": "patch",
  "merge_message": "x",
  "delete_ticket": false
}
''');
        final cfg = PublishConfig.load(
          configArg: 'release.json',
          fallbackDir: tmp.path,
        );
        expect(cfg.deleteTicket, isFalse);
      });

      test('leaves deleteTicket null when delete_ticket is unset', () async {
        await writeConfig('release.json', '''
{
  "version_increment": "patch",
  "merge_message": "x"
}
''');
        final cfg = PublishConfig.load(
          configArg: 'release.json',
          fallbackDir: tmp.path,
        );
        expect(cfg.deleteTicket, isNull);
      });

      test('rejects a non-boolean delete_ticket', () async {
        await writeConfig('release.json', '''
{
  "version_increment": "patch",
  "merge_message": "x",
  "delete_ticket": "yes"
}
''');
        expect(
          () => PublishConfig.load(
            configArg: 'release.json',
            fallbackDir: tmp.path,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"delete_ticket" must be a boolean'),
            ),
          ),
        );
      });
    });

    group('resolveSingle()', () {
      test('returns the top-level values when both are present', () {
        final cfg = PublishConfig(
          versionIncrement: 'minor',
          mergeMessage: 'release X',
        );
        final r = cfg.resolveSingle(configPath: 'release.json');
        expect(r.versionIncrement, 'minor');
        expect(r.mergeMessage, 'release X');
      });

      test('hard errors when version_increment is missing', () {
        final cfg = PublishConfig(mergeMessage: 'release X');
        expect(
          () => cfg.resolveSingle(configPath: 'release.json'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('version_increment'),
            ),
          ),
        );
      });

      test('accepts a missing increment for a merge-only run', () {
        // A merge-only run releases nothing, so it needs no increment.
        final cfg = PublishConfig(mergeMessage: 'merge X');
        final r = cfg.resolveSingle(
          configPath: 'release.json',
          requireVersionIncrement: false,
        );
        expect(r.versionIncrement, isNull);
        expect(r.mergeMessage, 'merge X');
      });

      test('hard errors when merge_message is missing', () {
        final cfg = PublishConfig(versionIncrement: 'minor');
        expect(
          () => cfg.resolveSingle(configPath: 'release.json'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('merge_message'),
            ),
          ),
        );
      });

      test('enumerates all missing fields in a single error', () {
        final cfg = PublishConfig();
        expect(
          () => cfg.resolveSingle(configPath: 'release.json'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(contains('version_increment'), contains('merge_message')),
            ),
          ),
        );
      });
    });

    group('forRepo()', () {
      test('per-repo override beats the top-level default', () {
        final cfg = PublishConfig(
          versionIncrement: 'patch',
          mergeMessage: 'default',
          repos: {
            'app_core': RepoOverride(
              versionIncrement: 'minor',
              mergeMessage: 'custom',
            ),
          },
        );
        final r = cfg.forRepo(repoName: 'app_core', configPath: 'release.json');
        expect(r.versionIncrement, 'minor');
        expect(r.mergeMessage, 'custom');
      });

      test('falls back to top-level when override only sets one field', () {
        final cfg = PublishConfig(
          versionIncrement: 'patch',
          mergeMessage: 'default',
          repos: {'app_core': RepoOverride(mergeMessage: 'only message')},
        );
        final r = cfg.forRepo(repoName: 'app_core', configPath: 'release.json');
        expect(r.versionIncrement, 'patch');
        expect(r.mergeMessage, 'only message');
      });

      test('uses top-level defaults when no override is registered', () {
        final cfg = PublishConfig(
          versionIncrement: 'patch',
          mergeMessage: 'default',
        );
        final r = cfg.forRepo(repoName: 'unknown', configPath: 'release.json');
        expect(r.versionIncrement, 'patch');
        expect(r.mergeMessage, 'default');
      });

      test('accepts a missing increment for a merge-only run', () {
        final cfg = PublishConfig(
          mergeMessage: 'default',
          repos: {'app_core': RepoOverride(mergeMessage: 'merge it')},
        );
        final r = cfg.forRepo(
          repoName: 'app_core',
          configPath: 'release.json',
          requireVersionIncrement: false,
        );
        expect(r.versionIncrement, isNull);
        expect(r.mergeMessage, 'merge it');
      });

      test(
        'hard errors when neither override nor top-level supplies a value',
        () {
          final cfg = PublishConfig(
            mergeMessage: 'default',
            repos: {'app_core': RepoOverride()},
          );
          expect(
            () => cfg.forRepo(repoName: 'app_core', configPath: 'release.json'),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                allOf(
                  contains('version_increment'),
                  contains('repos.app_core'),
                ),
              ),
            ),
          );
        },
      );

      test(
        'hard errors when merge_message is missing on both override + default',
        () {
          // Neither top-level nor override supplies `merge_message`.
          final cfg = PublishConfig(
            versionIncrement: 'patch',
            repos: {'app_core': RepoOverride()},
          );
          expect(
            () => cfg.forRepo(repoName: 'app_core', configPath: 'release.json'),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                allOf(contains('merge_message'), contains('repos.app_core')),
              ),
            ),
          );
        },
      );
    });

    group('parseVersionIncrement()', () {
      test('maps the three valid strings to VersionIncrement', () {
        expect(parseVersionIncrement('patch'), VersionIncrement.patch);
        expect(parseVersionIncrement('minor'), VersionIncrement.minor);
        expect(parseVersionIncrement('major'), VersionIncrement.major);
      });

      test('throws ArgumentError for an unknown increment', () {
        expect(
          () => parseVersionIncrement('huge'),
          throwsA(isA<ArgumentError>()),
        );
      });
    });

    test('allowedVersionIncrements covers exactly patch/minor/major', () {
      expect(allowedVersionIncrements, equals({'patch', 'minor', 'major'}));
    });

    test('allowedPublishStatuses covers exactly '
        'pending/published/failed/skipped', () {
      expect(
        allowedPublishStatuses,
        equals({'pending', 'published', 'failed', 'skipped'}),
      );
    });

    group('status parsing in load()', () {
      test('parses a valid per-repo status', () async {
        await writeConfig('release.json', '''
{
  "version_increment": "patch",
  "merge_message": "x",
  "repos": {
    "foo": {
      "version_increment": "minor",
      "merge_message": "m",
      "status": "published"
    }
  }
}
''');
        final cfg = PublishConfig.load(
          configArg: 'release.json',
          fallbackDir: tmp.path,
        );
        expect(cfg.repos['foo']!.status, 'published');
      });

      test('parses the skipped per-repo status', () async {
        await writeConfig('release.json', '''
{
  "version_increment": "patch",
  "merge_message": "x",
  "repos": {
    "foo": { "status": "skipped" }
  }
}
''');
        final cfg = PublishConfig.load(
          configArg: 'release.json',
          fallbackDir: tmp.path,
        );
        expect(cfg.repos['foo']!.status, 'skipped');
      });

      test('rejects an unknown status with an enumerating error', () async {
        await writeConfig('release.json', '''
{
  "version_increment": "patch",
  "merge_message": "x",
  "repos": {
    "foo": { "status": "halfway" }
  }
}
''');
        expect(
          () => PublishConfig.load(
            configArg: 'release.json',
            fallbackDir: tmp.path,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('status'),
                contains('pending'),
                contains('published'),
                contains('failed'),
              ),
            ),
          ),
        );
      });
    });

    group('toJson()', () {
      test('emits every set field including per-repo status', () {
        final cfg = PublishConfig(
          versionIncrement: 'patch',
          mergeMessage: 'top',
          deleteTicket: true,
          repos: {
            'foo': RepoOverride(
              versionIncrement: 'minor',
              mergeMessage: 'm',
              status: 'published',
            ),
          },
        );
        expect(cfg.toJson(), <String, dynamic>{
          'version_increment': 'patch',
          'merge_message': 'top',
          'delete_ticket': true,
          'repos': <String, dynamic>{
            'foo': <String, dynamic>{
              'version_increment': 'minor',
              'merge_message': 'm',
              'status': 'published',
            },
          },
        });
      });

      test('omits null fields and an empty repos section', () {
        expect(PublishConfig().toJson(), <String, dynamic>{});
      });
    });

    group('save()', () {
      test('round-trips through load() and writes no BOM', () async {
        final cfg = PublishConfig(
          deleteTicket: false,
          repos: {
            'foo': RepoOverride(
              versionIncrement: 'major',
              mergeMessage: 'release foo',
              status: 'pending',
            ),
          },
        );
        // Parent `.gg/` does not exist yet — save() must create it.
        final file = File(p.join(tmp.path, '.gg', 'gg-publish.json'));
        await cfg.save(file: file);
        expect(file.existsSync(), isTrue);

        final bytes = await file.readAsBytes();
        expect(bytes.take(3), isNot(equals(<int>[0xEF, 0xBB, 0xBF])));

        final reloaded = PublishConfig.load(
          configArg: file.path,
          fallbackDir: tmp.path,
        );
        expect(reloaded.deleteTicket, isFalse);
        expect(reloaded.repos['foo']!.versionIncrement, 'major');
        expect(reloaded.repos['foo']!.mergeMessage, 'release foo');
        expect(reloaded.repos['foo']!.status, 'pending');
      });

      test('writes into an existing directory too', () async {
        final cfg = PublishConfig(versionIncrement: 'patch', mergeMessage: 'x');
        // Parent (tmp) already exists — exercises the no-create branch.
        final file = File(p.join(tmp.path, '.gg-publish.json'));
        await cfg.save(file: file);
        final decoded = jsonDecode(await file.readAsString());
        expect(decoded['version_increment'], 'patch');
      });
    });

    group('withRepoStatus() / statusForRepo()', () {
      test('sets the status while preserving the repo config values', () {
        final cfg = PublishConfig(
          repos: {
            'foo': RepoOverride(versionIncrement: 'minor', mergeMessage: 'm'),
          },
        );
        final updated = cfg.withRepoStatus('foo', 'published');
        expect(updated.statusForRepo('foo'), 'published');
        expect(updated.repos['foo']!.versionIncrement, 'minor');
        expect(updated.repos['foo']!.mergeMessage, 'm');
        // Original stays untouched (immutability).
        expect(cfg.statusForRepo('foo'), isNull);
      });

      test('adds a marker for a repo that had no override yet', () {
        final cfg = PublishConfig(versionIncrement: 'patch', mergeMessage: 'x');
        final updated = cfg.withRepoStatus('newRepo', 'failed');
        expect(updated.statusForRepo('newRepo'), 'failed');
        expect(updated.repos['newRepo']!.versionIncrement, isNull);
      });

      test('statusForRepo returns null for an unknown repo', () {
        expect(PublishConfig().statusForRepo('nope'), isNull);
      });
    });

    group('done_steps parsing in load()', () {
      test('parses a valid done_steps list and dedupes entries', () async {
        await writeConfig('cfg.json', '''
{
  "version_increment": "patch",
  "merge_message": "m",
  "done_steps": ["prepare_version", "merge", "prepare_version"]
}
''');
        final cfg = PublishConfig.load(
          configArg: 'cfg.json',
          fallbackDir: tmp.path,
        );
        expect(cfg.doneSteps, ['prepare_version', 'merge']);
        expect(cfg.isStepDone('merge'), isTrue);
        expect(cfg.isStepDone('tag'), isFalse);
        expect(cfg.hasStepProgress, isTrue);
      });

      test('rejects a non-list done_steps', () async {
        await writeConfig('cfg.json', '{"done_steps": "merge"}');
        expect(
          () =>
              PublishConfig.load(configArg: 'cfg.json', fallbackDir: tmp.path),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('must be a list of strings'),
            ),
          ),
        );
      });

      test('rejects unknown step names with an enumerating error', () async {
        await writeConfig('cfg.json', '{"done_steps": ["fly_to_moon"]}');
        expect(
          () =>
              PublishConfig.load(configArg: 'cfg.json', fallbackDir: tmp.path),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(contains('prepare_version'), contains('fly_to_moon')),
            ),
          ),
        );
      });
    });

    group('withStepDone() / isStepDone()', () {
      test('appends steps in completion order and is idempotent', () {
        final cfg = PublishConfig(versionIncrement: 'patch', mergeMessage: 'm')
            .withStepDone('prepare_version')
            .withStepDone('publish_registry')
            .withStepDone('prepare_version'); // no-op
        expect(cfg.doneSteps, ['prepare_version', 'publish_registry']);
        // The original config values survive the copies.
        expect(cfg.versionIncrement, 'patch');
        expect(cfg.mergeMessage, 'm');
      });

      test('throws ArgumentError for an unknown step', () {
        expect(
          () => PublishConfig().withStepDone('fly_to_moon'),
          throwsArgumentError,
        );
      });

      test('withRepoStatus preserves doneSteps', () {
        final cfg = PublishConfig(
          versionIncrement: 'patch',
          mergeMessage: 'm',
        ).withStepDone('merge').withRepoStatus('foo', 'published');
        expect(cfg.doneSteps, ['merge']);
      });

      test(
        'branch round-trips and survives withStepDone/withRepoStatus',
        () async {
          final cfg = PublishConfig(
            versionIncrement: 'patch',
            mergeMessage: 'm',
            branch: 'feat_abc',
          ).withStepDone('merge').withRepoStatus('foo', 'published');
          expect(cfg.branch, 'feat_abc');
          expect(cfg.toJson()['branch'], 'feat_abc');
          // Omitted when unset.
          expect(PublishConfig().toJson().containsKey('branch'), isFalse);

          final file = File(p.join(tmp.path, 'branch.json'));
          await cfg.save(file: file);
          final reloaded = PublishConfig.load(
            configArg: file.path,
            fallbackDir: tmp.path,
          );
          expect(reloaded.branch, 'feat_abc');
        },
      );

      test('delete_feature_branch round-trips and survives copies', () async {
        final cfg = PublishConfig(
          versionIncrement: 'patch',
          mergeMessage: 'm',
          deleteFeatureBranch: true,
        ).withStepDone('merge').withRepoStatus('foo', 'published');
        expect(cfg.deleteFeatureBranch, isTrue);
        expect(cfg.toJson()['delete_feature_branch'], isTrue);
        // Omitted when unset.
        expect(
          PublishConfig().toJson().containsKey('delete_feature_branch'),
          isFalse,
        );

        final file = File(p.join(tmp.path, 'dfb.json'));
        await cfg.save(file: file);
        final reloaded = PublishConfig.load(
          configArg: file.path,
          fallbackDir: tmp.path,
        );
        expect(reloaded.deleteFeatureBranch, isTrue);
      });

      test('rejects a non-boolean delete_feature_branch', () async {
        await writeConfig('cfg.json', '{"delete_feature_branch": "yes"}');
        expect(
          () =>
              PublishConfig.load(configArg: 'cfg.json', fallbackDir: tmp.path),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"delete_feature_branch" must be a boolean'),
            ),
          ),
        );
      });

      test('pr round-trips and survives copies', () async {
        final cfg = PublishConfig(
          versionIncrement: 'patch',
          mergeMessage: 'm',
          pr: false,
        ).withStepDone('merge').withRepoStatus('foo', 'published');
        expect(cfg.pr, isFalse);
        expect(cfg.toJson()['pr'], isFalse);
        // Omitted when unset.
        expect(PublishConfig().toJson().containsKey('pr'), isFalse);

        final file = File(p.join(tmp.path, 'pr.json'));
        await cfg.save(file: file);
        final reloaded = PublishConfig.load(
          configArg: file.path,
          fallbackDir: tmp.path,
        );
        expect(reloaded.pr, isFalse);
      });

      test('rejects a non-boolean pr', () async {
        await writeConfig('cfg.json', '{"pr": "yes"}');
        expect(
          () =>
              PublishConfig.load(configArg: 'cfg.json', fallbackDir: tmp.path),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"pr" must be a boolean'),
            ),
          ),
        );
      });

      test('done_steps round-trips through toJson/save/load', () async {
        final cfg = PublishConfig(
          versionIncrement: 'minor',
          mergeMessage: 'msg',
        ).withStepDone('prepare_version');
        expect(cfg.toJson()['done_steps'], ['prepare_version']);
        // An empty list is omitted from the JSON.
        expect(PublishConfig().toJson().containsKey('done_steps'), isFalse);

        final file = File(p.join(tmp.path, 'rt.json'));
        await cfg.save(file: file);
        final reloaded = PublishConfig.load(
          configArg: file.path,
          fallbackDir: tmp.path,
        );
        expect(reloaded.doneSteps, ['prepare_version']);
      });

      test('channel round-trips and survives copies', () async {
        final cfg = PublishConfig(
          versionIncrement: 'minor',
          mergeMessage: 'm',
          channel: 'rc',
        ).withStepDone('merge').withRepoStatus('foo', 'published');
        expect(cfg.channel, 'rc');
        expect(cfg.toJson()['channel'], 'rc');
        // Omitted when unset.
        expect(PublishConfig().toJson().containsKey('channel'), isFalse);

        final file = File(p.join(tmp.path, 'ch.json'));
        await cfg.save(file: file);
        final reloaded = PublishConfig.load(
          configArg: file.path,
          fallbackDir: tmp.path,
        );
        expect(reloaded.channel, 'rc');
      });

      test('per-repo channel overrides the top-level default', () async {
        await writeConfig(
          'cfg.json',
          '{"version_increment": "patch", "merge_message": "m", '
              '"channel": "stable", '
              '"repos": {"foo": {"channel": "rc"}, "bar": {}}}',
        );
        final cfg = PublishConfig.load(
          configArg: 'cfg.json',
          fallbackDir: tmp.path,
        );
        expect(cfg.channelForRepo('foo'), 'rc');
        expect(cfg.channelForRepo('bar'), 'stable');
        expect(cfg.channelForRepo('unknown'), 'stable');
        expect(cfg.repos['foo']!.toJson()['channel'], 'rc');
      });

      test('rejects an unknown channel', () async {
        await writeConfig('cfg.json', '{"channel": "nightly"}');
        expect(
          () =>
              PublishConfig.load(configArg: 'cfg.json', fallbackDir: tmp.path),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"channel" must be one of'),
            ),
          ),
        );
      });

      test('parseReleaseChannel maps strings and rejects unknowns', () {
        expect(parseReleaseChannel('stable'), ReleaseChannel.stable);
        expect(parseReleaseChannel('rc'), ReleaseChannel.rc);
        expect(
          () => parseReleaseChannel('nightly'),
          throwsA(isA<ArgumentError>()),
        );
      });
    });

    group('unfinishedPublishMessage', () {
      test('names the file and both ways out, one per line', () {
        expect(
          rmC(
            unfinishedPublishMessage(
              path: '/tmp/x/.gg/gg-publish.json',
              command: 'gg do publish',
            ),
          ),
          'Unfinished publish in /tmp/x/.gg/gg-publish.json\n'
          '  Continue:gg do publish --continue\n'
          '  Restart: gg do publish --restart',
        );
      });

      test('carries the command of the caller, e.g. a merge-only run', () {
        expect(
          rmC(
            unfinishedPublishMessage(
              path: 'p',
              command: 'gg do publish --merge-only',
            ),
          ),
          'Unfinished publish in p\n'
          '  Continue:gg do publish --merge-only --continue\n'
          '  Restart: gg do publish --merge-only --restart',
        );
      });

      test('marks the path as an error and the commands as commands', () {
        final message = unfinishedPublishMessage(
          path: 'p',
          command: 'gg do publish',
        );
        expect(message, contains(cError('Unfinished publish in p')));
        expect(message, contains(cCmd('gg do publish --continue')));
      });

      test('no line of it exceeds the terminal width', () {
        final lines = rmC(
          unfinishedPublishMessage(
            path: '.gg/gg-publish.json',
            command: 'gg do publish',
          ),
        ).split('\n');
        for (final line in lines) {
          expect(line.length, lessThanOrEqualTo(72), reason: line);
        }
      });
    });

    test('continueConflictMessage explains the conflict in short lines', () {
      final lines = rmC(continueConflictMessage).split('\n');
      expect(lines.first, contains('cannot be combined'));
      for (final line in lines) {
        expect(line.length, lessThanOrEqualTo(72), reason: line);
      }
    });

    test('allowedPublishSteps covers exactly the four tracked steps', () {
      // The feature-branch deletion is idempotent and re-runs on resume,
      // so it is deliberately not a tracked step.
      expect(allowedPublishSteps, {
        'prepare_version',
        'publish_registry',
        'merge',
        'tag',
      });
    });
  });
}
