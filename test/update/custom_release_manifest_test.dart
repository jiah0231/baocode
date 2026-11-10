import 'dart:convert';
import 'dart:io';

import 'package:baocode/update/update_manifest.dart';
import 'package:baocode/update/update_signature.dart';
import 'package:baocode/update/version.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/custom_release_manifest.dart';

void main() {
  test('manifest uses notes for the exact current version', () {
    final notes = readCustomReleaseNotes(Directory.current, currentAppVersion);
    expect(notes.keys, containsAll(['zh', 'en']));
    expect(notes['zh'], contains('窗口'));
    expect(notes['en'], contains('v1.9.2'));
    expect(
      () =>
          readCustomReleaseNotes(Directory.current, AppVersion.parse('0.0.0')),
      throwsA(isA<FileSystemException>()),
    );
  });

  // Deliberately public test seeds, never release credentials.
  final seed = base64Encode(List.filled(32, 1));
  final otherKey = UpdateSignature.publicKeyOf(
    base64Encode(List.filled(32, 2)),
  );
  final publicKey = UpdateSignature.publicKeyOf(seed);
  final previousVersion = AppVersion.parse('1.9.1+46');
  final next = AppVersion.parse('1.9.1+47');
  final hash = 'a' * 64;
  final signature = UpdateSignature.sign(
    payload: UpdateSignature.payload(
      version: '$previousVersion',
      platform: 'windows-x64',
      size: 10,
      sha256: hash,
    ),
    seed: seed,
  );
  UpdateManifest previous({String? digest}) => UpdateManifest.fromJson({
    'version': '$previousVersion',
    'platforms': {
      'windows-x64': {
        'url': 'https://github.com/jiah0231/baocode/releases/download/custom-v1.9.1+46/BaoCode-1.9.1-setup.exe',
        'size': 10,
        'sha256': digest ?? hash,
        'signature': signature,
      },
    },
  }, policy: const UpdateUrlPolicy(custom: true));

  test(
    'existing custom authority advances without rotating the trusted key',
    () {
      expect(
        () => verifyPreviousCustomRelease(
          previous(),
          next,
          'windows-x64',
          publicKey,
        ),
        returnsNormally,
      );
    },
  );
  test('rejects changed authority, tampered manifest and missing platform', () {
    for (final (manifest, platform, key) in [
      (previous(), 'windows-x64', otherKey),
      (previous(digest: 'b' * 64), 'windows-x64', publicKey),
      (previous(), 'windows-arm64', publicKey),
    ]) {
      expect(
        () => verifyPreviousCustomRelease(manifest, next, platform, key),
        throwsStateError,
      );
    }
  });
  test('rejects duplicate versions and rollback despite a valid signature', () {
    for (final version in [previousVersion, AppVersion.parse('1.9.1+45')]) {
      expect(
        () => verifyPreviousCustomRelease(
          previous(),
          version,
          'windows-x64',
          publicKey,
        ),
        throwsStateError,
      );
    }
  });
}
