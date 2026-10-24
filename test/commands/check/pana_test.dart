// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gg_git/gg_git_test_helpers.dart';
import 'package:gg_lang/gg_lang.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_publish/gg_publish.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:gg_version/gg_version.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  final messages = <String>[];

  // Strip the colors so the expectations stay readable. One closure
  // instance, not a function declaration: mocktail matches the ggLog
  // argument by identity, and a tear-off is not stable.
  // ignore: prefer_function_declarations_over_variables
  final GgLog ggLog = (String msg) => messages.add(rmControls(msg));
  final panaCmd = Platform.isWindows ? 'pana.bat' : 'pana';

  late GgProcessWrapper processWrapper;
  late MockPublishedVersion publishedVersion;
  late MockFromGit versionFromGit;
  late Pana pana;
  late CommandRunner<void> runner;
  late Directory d;

  /// The version the package has on pub.dev in the default setup.
  final released = Version(1, 0, 0);

  final successReport = File('test/data/pana_success_report.json')
      .readAsStringSync();

  final versionMissedReport = File(
    'test/data/pana_version_in_changelog_missing.json',
  ).readAsStringSync();

  // .........................................................................
  void mockPanaIsInstalled({
    required bool isInstalled,
    int exitCode = 0,
    String stderr = '',
  }) {
    String response = '';
    response += 'cider 0.2.7\n';
    response += 'gg 3.0.2\n';
    if (isInstalled) {
      response += 'pana 0.22.2';
    }

    when(() => processWrapper.run('dart', ['pub', 'global', 'list']))
        .thenAnswer((_) async => ProcessResult(0, exitCode, response, stderr));
  }

  // ...........................................................................
  void mockPanaInstallation({required bool success, String stderr = ''}) {
    when(
      () => processWrapper.run('dart', ['pub', 'global', 'activate', 'pana']),
    ).thenAnswer((_) async {
      if (!success) {
        return ProcessResult(0, 1, '', stderr);
      }

      messages.add('Install pana');
      return ProcessResult(0, 0, '', '');
    });
  }

  // ...........................................................................
  /// The version pub.dev serves, or null when the package is not there yet.
  void mockPubDevVersion(Version? version) {
    when(
      () => publishedVersion.latestVersionFor(
        target: PublishTarget.pubDev,
        directory: any(named: 'directory'),
        ggLog: any(named: 'ggLog'),
      ),
    ).thenAnswer((_) async => version);
  }

  // ...........................................................................
  /// The version tags the repository carries.
  void mockGitVersionTags(List<Version> tags) {
    when(
      () => versionFromGit.allVersions(
        directory: any(named: 'directory'),
        ggLog: any(named: 'ggLog'),
      ),
    ).thenAnswer((_) async => tags);
  }

  // ...........................................................................
  setUpAll(() {
    registerFallbackValue(Directory(''));
    registerFallbackValue(ggLog);
  });

  // ...........................................................................
  setUp(() async {
    messages.clear();
    processWrapper = MockGgProcessWrapper();
    publishedVersion = MockPublishedVersion();
    versionFromGit = MockFromGit();
    pana = Pana(
      ggLog: ggLog,
      processWrapper: processWrapper,
      publishedVersion: publishedVersion,
      versionFromGit: versionFromGit,
    );
    runner = CommandRunner('test', 'test')..addCommand(pana);
    d = await Directory.systemTemp.createTemp('gg_test');
    await initCachedRepo(
      d,
      key: 'pana_base',
      build: (repo) async {
        await initGit(repo);
        await addAndCommitPubspecFile(repo);
      },
    );
    mockPanaIsInstalled(isInstalled: true);

    // The default is a package that already had a full release cycle — on
    // pub.dev and tagged here — so the tests below stay about pana itself.
    mockPubDevVersion(released);
    mockGitVersionTags([released]);
  });

  // ...........................................................................
  tearDown(() async {
    await d.delete(recursive: true);
  });

  // ...........................................................................
  void mockPanaResult(String json, {int exitCode = 0, String stderr = ''}) {
    when(
      () => processWrapper.run(panaCmd, [
        '--no-warning',
        '--json',
        '--no-dartdoc',
      ], workingDirectory: d.path),
    ).thenAnswer((_) async => ProcessResult(0, exitCode, json, stderr));
  }

  // ...........................................................................
  /// The message of the exception the pana run throws.
  Future<String> panaError() async {
    try {
      await runner.run(['pana', '--input', d.path]);
    } catch (e) {
      return rmControls(e.toString());
    }
    fail('pana did not fail');
  }

  // ...........................................................................
  group('Pana', () {
    // .........................................................................
    test('can be created without injected dependencies', () {
      expect(Pana(ggLog: ggLog), isNotNull);
    });

    // .........................................................................
    group('should throw an Exception', () {
      test('when pana returns invalid JSON', () async {
        // Mock process returning invalid JSON
        mockPanaResult('{"foo": "bar"');

        // Running process should throw an exception
        await expectLater(
          runner.run(['pana', '--input', d.path]),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'toString()',
              allOf(
                startsWith('Exception: Pana failed in ${d.path}\n'),
                contains(
                  'pana printed no valid JSON report (exit code 0): '
                  'FormatException: Unexpected end of input',
                ),
              ),
            ),
          ),
        );

        // Check result
        expect(messages[0], contains('⌛️ Running pana'));
        expect(messages[1], contains('✗ Running pana'));
      });

      test('when pana prints JSON that is no report', () async {
        // The JSON parses, so today's message stays.
        mockPanaResult('{"foo": "bar"}');

        expect(await panaError(), contains('Error parsing pana output'));
      });

      group('when pana prints no report', () {
        test('with the SEVERE and SHOUT records of its log', () async {
          // pana 0.23.17+ on Windows: the sandbox check rejects the »:« of
          // every temp folder, stdout stays empty, and the reason is only in
          // the JSON log pana writes to stderr.
          final stderr = [
            {'level': 'INFO', 'message': 'Checking pubspec'},
            {
              'logName': 'pana',
              'level': 'SEVERE',
              'message': 'Sandbox output folder must not contain ":"',
              'stackTrace': '#0 SandboxRunner.runSandboxed',
            },
            {
              'level': 'SHOUT',
              'message': 'Unexpected error',
              'error':
                  "LateInitializationError: Local 'repo' has not been "
                  'initialized.\nsecond line of the error',
              'stackTrace': '#0 main',
            },
          ].map(jsonEncode).join('\n');
          mockPanaResult('', exitCode: 1, stderr: stderr);

          final error = await panaError();

          expect(
            error,
            allOf(
              startsWith('Exception: Pana failed in ${d.path}\n'),
              contains('pana printed no JSON report (exit code 1).'),
              contains('SEVERE: Sandbox output folder must not contain ":"'),
              contains(
                'SHOUT: Unexpected error — '
                "LateInitializationError: Local 'repo' has not been "
                'initialized.',
              ),
            ),
          );
          // Only what names the failure: no stack traces, no other records,
          // no further lines of an error.
          expect(error, isNot(contains('#0')));
          expect(error, isNot(contains('Checking pubspec')));
          expect(error, isNot(contains('second line of the error')));
        });

        test('with the last lines of a stderr without log records', () async {
          final stderr = [
            '{broken',
            'early',
            for (var i = 0; i < 10; i++) 'late $i',
          ].join('\n');
          mockPanaResult('', exitCode: 255, stderr: stderr);

          final error = await panaError();

          expect(
            error,
            contains('pana printed no JSON report (exit code 255).'),
          );
          expect(error, contains('late 0\n'));
          expect(error, endsWith('late 9'));
          expect(error, isNot(contains('early')));
          expect(error, isNot(contains('{broken')));
        });
      });
    });

    // .........................................................................
    group('should succeed', () {
      test('when 140 pubpoints are reached', () async {
        // Mock an success report

        mockPanaResult(successReport);

        // Run pana
        await runner.run(['pana', '--input', d.path]);

        // Check result
        expect(messages[0], contains('⌛️ Running pana'));
        expect(messages[1], contains('✓ Running pana'));
      });

      test('when pana prints a preamble before the JSON', () async {
        // On a cold run pana prints e.g. "Resolving dependencies..." to
        // stdout before the JSON report. The preamble must be skipped.
        mockPanaResult('Resolving dependencies...\n$successReport');

        await runner.run(['pana', '--input', d.path]);

        expect(messages[0], contains('⌛️ Running pana'));
        expect(messages[1], contains('✓ Running pana'));
      });

      group('when the project has no manifest', () {
        test('skipping pana', () async {
          final emptyDir = Directory.systemTemp.createTempSync();
          try {
            await runner.run(['pana', '--input', emptyDir.path]);
            expect(
              messages[0],
              contains('✓ Skipping pana (no project manifest)'),
            );
          } finally {
            emptyDir.deleteSync(recursive: true);
          }
        });
      });

      group('when package is not published to pub.dev', () {
        test('and publishedOnly is set to true', () async {
          // Add publish_to: none
          await File(join(d.path, 'pubspec.yaml'))
              .writeAsString('publish_to: none');

          // Run pana
          await runner.run(['pana', '--input', d.path, '--published-only']);

          // Pana is skipped (not published to pub.dev) and says so explicitly.
          expect(messages[0], contains('✓ Skipping pana'));
          expect(messages[0], contains('none'));
        });

        test('for an npm-only hybrid', () async {
          // publish_to: none on the Dart side, public on npm.
          await File(join(d.path, 'pubspec.yaml'))
              .writeAsString('name: x\nversion: 1.0.0\npublish_to: none\n');
          await File(join(d.path, 'package.json'))
              .writeAsString('{"name": "@org/x", "version": "1.0.0"}');

          await runner.run(['pana', '--input', d.path, '--published-only']);

          expect(messages[0], contains('✓ Skipping pana'));
          expect(messages[0], contains('npm'));
        });
      });

      group('when the package had no release cycle yet', () {
        test('and pub.dev does not know it, skipping pana', () async {
          // The first publish: nothing is on pub.dev, so pana has no released
          // state to score against — its repository verification would fail
          // for a package the user cannot fix.
          mockPubDevVersion(null);

          await runner.run(['pana', '--input', d.path]);

          expect(messages[0], contains('✓ Skipping pana (not on pub.dev yet)'));
          verifyNever(
            () => versionFromGit.allVersions(
              directory: any(named: 'directory'),
              ggLog: any(named: 'ggLog'),
            ),
          );
        });

        test(
          'and the published version has no git tag, skipping pana',
          () async {
            // pub.dev serves 1.0.0, but this repository never tagged it — the
            // released state never arrived here, so pana cannot compare
            // against it.
            mockPubDevVersion(released);
            mockGitVersionTags([Version(0, 1, 0)]);

            await runner.run(['pana', '--input', d.path]);

            expect(messages[0], contains('✓ Skipping pana (no git tag 1.0.0)'));
          },
        );

        test(
          'and the repository carries no tag at all, skipping pana',
          () async {
            mockPubDevVersion(released);
            mockGitVersionTags([]);

            await runner.run(['pana', '--input', d.path]);

            expect(messages[0], contains('✓ Skipping pana (no git tag 1.0.0)'));
          },
        );
      });

      group('when a hybrid publishes to pub.dev too', () {
        test('pana runs', () async {
          // A package.json next to the pubspec does not take the package off
          // pub.dev — before this, the single publish target of a hybrid read
          // »npm« and pana was skipped for it.
          await File(join(d.path, 'pubspec.yaml'))
              .writeAsString('name: x\nversion: 1.0.0\n');
          await File(join(d.path, 'package.json'))
              .writeAsString('{"name": "@org/x", "version": "1.0.0"}');
          mockPanaResult(successReport);

          await runner.run(['pana', '--input', d.path, '--published-only']);

          expect(messages[0], contains('⌛️ Running pana'));
          expect(messages[1], contains('✓ Running pana'));
        });
      });

      test(
        'also, when version is not yet correctly set in CHANGELOG.md',
        () async {
          mockPanaResult(versionMissedReport);
          // Run pana
          await runner.run(['pana', '--input', d.path]);

          // Check result
          expect(messages[0], contains('⌛️ Running pana'));
          expect(messages[1], contains('✓ Running pana'));
        },
      );
    });

    group('should fail ', () {
      test('when 140 pubpoints are not reached', () async {
        // Mock an success report
        final notSuccessReport = File('test/data/pana_not_success_report.json')
            .readAsStringSync();
        mockPanaResult(notSuccessReport);

        // Run pana
        await expectLater(
          runner.run(['pana', '--input', d.path]),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'toString()',
              allOf(
                startsWith('Exception: Pana failed in ${d.path}\n'),
                contains('[x] 0/10 points: Provide a valid `pubspec.yaml`'),
                contains(
                  '* `pubspec.yaml` doesn\'t have a `repository` entry.',
                ),
              ),
            ),
          ),
        );

        // Check result
        expect(messages[0], contains('⌛️ Running pana'));
        expect(messages[1], contains('✗ Running pana'));
      });
    });

    test('should install pana when not installed', () async {
      // Mock pana not being installed
      mockPanaIsInstalled(isInstalled: false);

      // Mock pana installation
      mockPanaInstallation(success: true);

      mockPanaResult(successReport);

      // Run pana
      await runner.run(['pana', '--input', d.path]);

      expect(messages[1], contains('Install pana'));
    });

    group('should throw', () {
      test(
        ' if someshing goes wrong like checking if pana is installed',
        () async {
          // Mock pana not being installed
          mockPanaIsInstalled(
            isInstalled: false,
            exitCode: 1,
            stderr: 'Something went wrong',
          );

          // Run pana
          late String exception;
          try {
            await runner.run(['pana', '--input', d.path]);
          } catch (e) {
            exception = rmControls(e.toString());
          }
          expect(
            exception,
            contains(
              'Failed to check if pana is installed: Something went wrong',
            ),
          );
        },
      );

      test(' if someshing goes wrong while installing pana', () async {
        // Mock pana not being installed
        mockPanaIsInstalled(isInstalled: false);

        // Mock failing pana installation
        mockPanaInstallation(success: false, stderr: 'Something went wrong');

        // Run pana
        late String exception;
        try {
          await runner.run(['pana', '--input', d.path]);
        } catch (e) {
          exception = rmControls(e.toString());
        }
        expect(
          exception,
          contains('Failed to install pana: Something went wrong'),
        );
      });
    });
  });
}
