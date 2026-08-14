// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gg_git/gg_git_test_helpers.dart';
import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_publish/gg_publish.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:path/path.dart';
import 'package:test/test.dart';

/// Deterministic [InteractAdapter] returning queued indices and capturing
/// the option lists it is shown (to assert the version previews).
class _StubAdapter implements InteractAdapter {
  _StubAdapter(this._indices);
  final List<int> _indices;
  int _call = 0;
  final List<List<String>> capturedOptions = [];
  final List<int> capturedInitialIndices = [];

  @override
  Future<int> choose({
    required String message,
    required List<String> options,
    int initialIndex = 0,
  }) async {
    capturedOptions.add(options);
    capturedInitialIndices.add(initialIndex);
    final index = _indices[_call % _indices.length];
    _call++;
    return index;
  }
}

void main() {
  final messages = <String>[];
  final ggLog = messages.add;
  late Directory d;
  final capturedInitials = <String>[];

  setUp(() async {
    messages.clear();
    capturedInitials.clear();
    d = await Directory.systemTemp.createTemp('configure_publish_');
    await initCachedRepo(
      d,
      key: 'configure_publish_base',
      build: (repo) async {
        await initLocalGit(repo);
        await enableEolLf(repo);
        await addAndCommitSampleFile(
          repo,
          fileName: 'pubspec.yaml',
          content: 'name: test\nversion: 1.2.3\n',
        );
      },
    );
  });

  tearDown(() async {
    await d.delete(recursive: true);
  });

  DoConfigurePublish makeCommand({
    List<int> increments = const [0],
    _StubAdapter? adapter,
    EditMessage? editMessage,
    ConfirmDeleteFeatureBranch? confirmDeleteFeatureBranch,
  }) => DoConfigurePublish(
    ggLog: ggLog,
    versionSelector: VersionSelector(
      adapter: adapter ?? _StubAdapter(increments),
    ),
    editMessage:
        editMessage ??
        (String initial) async {
          capturedInitials.add(initial);
          return initial;
        },
    confirmDeleteFeatureBranch:
        confirmDeleteFeatureBranch ?? (_) async => false,
  );

  RepoPublishFiles reload() => loadRepoPublishFiles(d);

  group('DoConfigurePublish', () {
    test(
      'writes increment + message and gitignores the runtime file',
      () async {
        File(join(d.path, 'ticket.json'))
            .writeAsStringSync('{"description": "Ticket desc"}');

        final config = await makeCommand(increments: [1])
            .configure(directory: d, ggLog: ggLog);

        expect(config.config.versionIncrement, VersionIncrement.minor);
        expect(config.config.mergeMessage, 'Ticket desc');
        expect(capturedInitials, ['Ticket desc']);

        final reloaded = reload();
        expect(reloaded.config.versionIncrement, VersionIncrement.minor);
        expect(reloaded.config.mergeMessage, 'Ticket desc');

        // The runtime file was gitignored before it was written.
        final gitignore = File(join(d.path, '.gitignore')).readAsStringSync();
        expect(gitignore, contains('.gg/publish_config.json'));
        expect(gitignore, contains('.gg/publish_state.json'));
        expect(messages, [
          'Added .gg/publish_config.json, .gg/publish_state.json, '
              '.gg/gg-publish.json, .gg/pubspec_overrides_backup.yaml, '
              '.gg/pnpm_workspace_backup.yaml to .gitignore.',
        ]);
      },
    );

    group('delete-feature-branch decision', () {
      test('asks with the current branch name and stores the answer', () async {
        var promptedBranch = '';
        final config = await makeCommand(
          confirmDeleteFeatureBranch: (branch) async {
            promptedBranch = branch;
            return true;
          },
        ).configure(directory: d, ggLog: ggLog, mergeMessage: 'msg');

        // initLocalGit starts on the default branch.
        expect(promptedBranch, isNotEmpty);
        expect(config.state.deleteFeatureBranch, isTrue);
        expect(reload().state.deleteFeatureBranch, isTrue);
      });

      test('a preset skips the prompt', () async {
        final config =
            await makeCommand(
              confirmDeleteFeatureBranch: (_) async =>
                  fail('Prompt must not run for a preset decision.'),
            ).configure(
              directory: d,
              ggLog: ggLog,
              mergeMessage: 'msg',
              deleteFeatureBranch: false,
            );

        expect(config.state.deleteFeatureBranch, isFalse);
      });

      test('CLI --delete-feature-branch flows into the config', () async {
        final runner = CommandRunner<void>('gg', 'gg')
          ..addCommand(
            makeCommand(
              confirmDeleteFeatureBranch: (_) async =>
                  fail('Prompt must not run when the flag is given.'),
            ),
          );

        await runner.run([
          'configure-publish',
          '-i',
          d.path,
          '-m',
          'CLI message',
          '--delete-feature-branch',
        ]);

        expect(reload().state.deleteFeatureBranch, isTrue);
      });
    });

    test('a preset merge message skips the message prompt', () async {
      final command = makeCommand(
        editMessage: (_) async =>
            fail('Editor must not open for a preset message.'),
      );

      final config = await command.configure(
        directory: d,
        ggLog: ggLog,
        mergeMessage: '  Preset msg  ',
      );

      expect(config.config.mergeMessage, 'Preset msg');
    });

    test('a preset increment skips the increment prompt', () async {
      final adapter = _StubAdapter([0]);
      final config = await makeCommand(adapter: adapter).configure(
        directory: d,
        ggLog: ggLog,
        versionIncrement: 'major',
        mergeMessage: 'msg',
      );

      expect(config.config.versionIncrement, VersionIncrement.major);
      expect(adapter.capturedOptions, isEmpty);
    });

    test('an empty edit falls back to the ticket description', () async {
      File(join(d.path, 'ticket.json'))
          .writeAsStringSync('{"description": "Ticket desc"}');

      final config = await makeCommand(editMessage: (_) async => '   ')
          .configure(directory: d, ggLog: ggLog);

      expect(config.config.mergeMessage, 'Ticket desc');
    });

    test(
      'an empty edit without ticket.json falls back to Publish <dir>',
      () async {
        final config = await makeCommand(editMessage: (_) async => '')
            .configure(directory: d, ggLog: ggLog);

        expect(config.config.mergeMessage, 'Publish ${basename(d.path)}');
      },
    );

    group('merge-message default from ticket.json', () {
      test('empty when ticket.json is malformed JSON (no crash)', () async {
        File(join(d.path, 'ticket.json')).writeAsStringSync('{"description":');
        await makeCommand().configure(directory: d, ggLog: ggLog);
        expect(capturedInitials, ['']);
      });

      test('empty when ticket.json is not a JSON object', () async {
        File(join(d.path, 'ticket.json')).writeAsStringSync('[]');
        await makeCommand().configure(directory: d, ggLog: ggLog);
        expect(capturedInitials, ['']);
      });

      test('empty when the description is blank', () async {
        File(join(d.path, 'ticket.json'))
            .writeAsStringSync('{"description": "   "}');
        await makeCommand().configure(directory: d, ggLog: ggLog);
        expect(capturedInitials, ['']);
      });
    });

    group('version preview baseline', () {
      test('uses the pubspec version when readable', () async {
        final adapter = _StubAdapter([0]);
        await makeCommand(adapter: adapter)
            .configure(directory: d, ggLog: ggLog, mergeMessage: 'msg');
        expect(adapter.capturedOptions.first.first, contains('1.2.3'));
      });

      test('falls back to package.json for TypeScript repos', () async {
        File(join(d.path, 'pubspec.yaml')).deleteSync();
        File(join(d.path, 'package.json'))
            .writeAsStringSync('{"name": "x", "version": "2.5.0"}');

        final adapter = _StubAdapter([0]);
        await makeCommand(adapter: adapter)
            .configure(directory: d, ggLog: ggLog, mergeMessage: 'msg');
        expect(adapter.capturedOptions.first.first, contains('2.5.0'));
      });

      test('falls back to 0.0.0 without any manifest', () async {
        File(join(d.path, 'pubspec.yaml')).deleteSync();

        final adapter = _StubAdapter([0]);
        await makeCommand(adapter: adapter)
            .configure(directory: d, ggLog: ggLog, mergeMessage: 'msg');
        expect(adapter.capturedOptions.first.first, contains('0.0.0'));
      });

      test(
        'falls back to the latest git version tag without any manifest',
        () async {
          File(join(d.path, 'pubspec.yaml')).deleteSync();
          await commitFile(d, '.', message: 'Remove pubspec.yaml');
          await addTags(d, ['3.1.4']);

          final adapter = _StubAdapter([0]);
          await makeCommand(adapter: adapter)
              .configure(directory: d, ggLog: ggLog, mergeMessage: 'msg');
          expect(adapter.capturedOptions.first.first, contains('3.1.4'));
        },
      );
    });

    group('file locations', () {
      test('configFileFor/stateFileFor name the two new files', () {
        expect(
          DoConfigurePublish.configFileFor(d).path,
          join(d.path, '.gg', 'publish_config.json'),
        );
        expect(
          DoConfigurePublish.stateFileFor(d).path,
          join(d.path, '.gg', 'publish_state.json'),
        );
      });

      test('legacyPublishConfigFile renames the hidden runtime file', () {
        // A publish that stopped before the files inside .gg were unhidden
        // left its progress behind - --continue has to find it.
        final ggDir = Directory(join(d.path, '.gg'))..createSync();
        final legacy = File(join(ggDir.path, '.gg-publish.json'))
          ..writeAsStringSync('{"done_steps":["prepare_version"]}');

        final file = legacyPublishConfigFile(d);

        expect(file.path, join(ggDir.path, 'gg-publish.json'));
        expect(file.readAsStringSync(), '{"done_steps":["prepare_version"]}');
        expect(legacy.existsSync(), isFalse);
      });

      test('legacyPublishConfigFile keeps the unhidden file when both '
          'exist', () {
        final ggDir = Directory(join(d.path, '.gg'))..createSync();
        File(join(ggDir.path, '.gg-publish.json'))
            .writeAsStringSync('{"merge_message":"legacy"}');
        File(join(ggDir.path, 'gg-publish.json'))
            .writeAsStringSync('{"merge_message":"current"}');

        expect(
          legacyPublishConfigFile(d).readAsStringSync(),
          '{"merge_message":"current"}',
        );
      });
    });

    test('refuses to clobber the progress of an unfinished publish', () async {
      final file = DoConfigurePublish.stateFileFor(d)
        ..createSync(recursive: true);
      file.writeAsStringSync('''
{
  "doneSteps": ["prepare_version", "publish_registry"]
}
''');

      await expectLater(
        () => makeCommand().configure(directory: d, ggLog: ggLog),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Unfinished publish in'),
          ),
        ),
      );
      // The file is untouched — the progress survives.
      final reloaded = reload();
      expect(reloaded.state.doneSteps, ['prepare_version', 'publish_registry']);
    });

    test(
      'refuses when the progress sits in a legacy gg-publish.json',
      () async {
        File(join(d.path, '.gg', 'gg-publish.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
{
  "version_increment": "patch",
  "merge_message": "m",
  "done_steps": ["prepare_version"]
}
''');

        await expectLater(
          () => makeCommand().configure(directory: d, ggLog: ggLog),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              contains('Unfinished publish in'),
            ),
          ),
        );
      },
    );

    test('a legacy gg-publish.json pre-selects the recorded answers', () async {
      File(join(d.path, '.gg', 'gg-publish.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '{"version_increment":"major","merge_message":"Legacy msg"}',
        );

      final adapter = _StubAdapter([2]);
      final config = await makeCommand(adapter: adapter)
          .configure(directory: d, ggLog: ggLog);

      // The prompt ran again — with the recorded answers pre-selected.
      expect(adapter.capturedInitialIndices, [2]);
      expect(capturedInitials, ['Legacy msg']);
      expect(config.config.versionIncrement, VersionIncrement.major);
      expect(config.config.mergeMessage, 'Legacy msg');
      // Only the new files are written; the legacy one stays untouched.
      expect(DoConfigurePublish.configFileFor(d).existsSync(), isTrue);
    });

    test('an existing config pre-selects instead of skipping', () async {
      await RepoPublishConfig(
        mergeMessage: 'Recorded msg',
        versionIncrement: VersionIncrement.minor,
      ).save(file: DoConfigurePublish.configFileFor(d));

      final adapter = _StubAdapter([1]);
      await makeCommand(adapter: adapter).configure(directory: d, ggLog: ggLog);

      expect(adapter.capturedOptions, hasLength(1));
      expect(adapter.capturedInitialIndices, [1]);
      expect(capturedInitials, ['Recorded msg']);
    });

    test(
      'carries nextCommitMessage and commits through a reconfigure',
      () async {
        await RepoPublishConfig(
          nextCommitMessage: CommitMessage(firstLine: 'Next'),
          commits: [
            CommitMessage(firstLine: 'Done', details: ['d0']),
          ],
        ).save(file: DoConfigurePublish.configFileFor(d));

        final config = await makeCommand().configure(
          directory: d,
          ggLog: ggLog,
          versionIncrement: 'patch',
          mergeMessage: 'msg',
        );

        expect(config.config.nextCommitMessage?.firstLine, 'Next');
        expect(config.config.commits.single.firstLine, 'Done');
        expect(reload().config.commits.single.details, ['d0']);
      },
    );

    test('overwrites a progress-free config file without complaint', () async {
      final file = DoConfigurePublish.configFileFor(d)
        ..createSync(recursive: true);
      file.writeAsStringSync(
        '{"publishConfig":{"versionIncrement":"patch","mergeMessage":"old"}}',
      );

      final config = await makeCommand().configure(
        directory: d,
        ggLog: ggLog,
        versionIncrement: 'minor',
        mergeMessage: 'new',
      );

      expect(config.config.mergeMessage, 'new');
      expect(reload().config.mergeMessage, 'new');
    });

    test('--merge-only asks for no version increment', () async {
      // A merge creates no release, so no increment is asked for (the empty
      // increment list would throw if the selector were used) and none is
      // written into the configuration.
      final runner = CommandRunner<void>('gg', 'gg')
        ..addCommand(makeCommand(increments: const []));

      await runner.run([
        'configure-publish',
        '-i',
        d.path,
        '-m',
        'Merge message',
        '--merge-only',
      ]);

      final reloaded = reload();
      expect(reloaded.config.versionIncrement, isNull);
      expect(reloaded.config.mergeMessage, 'Merge message');
    });

    test('CLI run resolves the directory and honours -m', () async {
      final runner = CommandRunner<void>('gg', 'gg')
        ..addCommand(makeCommand(increments: [2]));

      await runner.run([
        'configure-publish',
        '-i',
        d.path,
        '-m',
        'CLI message',
      ]);

      final reloaded = reload();
      expect(reloaded.config.versionIncrement, VersionIncrement.major);
      expect(reloaded.config.mergeMessage, 'CLI message');
    });
  });
}
