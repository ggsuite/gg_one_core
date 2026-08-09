// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_one_core/gg_one_core.dart';
import 'package:test/test.dart';

void main() {
  group('isGgOwnedPath(path)', () {
    test('matches manifests and lock files by basename', () {
      // The monorepo case: the package lives in a subfolder — matching the
      // full path silently stopped recognizing exactly these.
      expect(isGgOwnedPath('pubspec.yaml'), isTrue);
      expect(isGgOwnedPath('packages/x/pubspec.yaml'), isTrue);
      expect(isGgOwnedPath('apps/web/package.json'), isTrue);
      expect(isGgOwnedPath('packages/x/pubspec.lock'), isTrue);
      expect(isGgOwnedPath('a/b/c/pnpm-lock.yaml'), isTrue);
      expect(isGgOwnedPath('sub/CHANGELOG.md'), isTrue);
    });

    test('matches the .gg directory at any depth', () {
      expect(isGgOwnedPath('.gg/gg.json'), isTrue);
      expect(isGgOwnedPath('.gg/'), isTrue);
      expect(isGgOwnedPath('packages/x/.gg/gg.json'), isTrue);
    });

    test('matches root-only files at the root only', () {
      expect(isGgOwnedPath('.gitignore'), isTrue);
      expect(isGgOwnedPath('.gitattributes'), isTrue);
      expect(isGgOwnedPath('.gg.json'), isTrue);
      expect(isGgOwnedPath('.gg_localize_refs_backup.json'), isTrue);

      // A nested .gitignore is the user's.
      expect(isGgOwnedPath('lib/.gitignore'), isFalse);
      expect(isGgOwnedPath('sub/.gitattributes'), isFalse);
    });

    test('matches generated version files and their mirror tests', () {
      expect(isGgOwnedPath('lib/src/gg_git_version.dart'), isTrue);
      expect(isGgOwnedPath('test/gg_git_version_test.dart'), isTrue);
      expect(isGgOwnedPath('src/base_dna_version.ts'), isTrue);
      expect(isGgOwnedPath('test/base_dna_version.test.ts'), isTrue);
      expect(isGgOwnedPath('packages/x/lib/src/foo_version.dart'), isTrue);

      // Similar names that are NOT the generated pattern stay the user's.
      expect(isGgOwnedPath('lib/foo_version.dart'), isFalse);
      expect(isGgOwnedPath('lib/src/version.dart'), isFalse);
      expect(isGgOwnedPath('lib/src/foo_version_extra.dart'), isFalse);
    });

    test('answers false for user files and undecidable paths', () {
      expect(isGgOwnedPath('lib/user_code.dart'), isFalse);
      expect(isGgOwnedPath('README.md'), isFalse);
      expect(isGgOwnedPath(''), isFalse);
      expect(isGgOwnedPath('   '), isFalse);
      // A path git quoted does not name the file as written — user's.
      expect(isGgOwnedPath('"weird name.dart"'), isFalse);
    });

    test('tolerates a leading ./', () {
      expect(isGgOwnedPath('./pubspec.yaml'), isTrue);
      expect(isGgOwnedPath('./lib/user_code.dart'), isFalse);
    });
  });

  group('the relationship to GgState.ignoreFiles', () {
    test('every state-hash-ignored file is gg owned', () {
      // A file that does not influence the recorded check results is, by
      // definition, gg-generated noise. If it were not gg owned, the system
      // commit would create a user commit for a file gg itself wrote.
      for (final file in GgState.ignoreFiles) {
        expect(
          isGgOwnedPath(file),
          isTrue,
          reason:
              '»$file« is in GgState.ignoreFiles but not gg owned — '
              'the two lists drifted apart.',
        );
      }
    });
  });
}
