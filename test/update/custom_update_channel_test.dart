import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/update/custom_update_channel.dart';
import 'package:baocode/update/update_manifest.dart';
import 'package:baocode/update/update_service.dart';
import 'package:baocode/update/update_signature.dart';
import 'package:baocode/update/update_io.dart';
import 'package:baocode/update/installer_io.dart';
import 'package:baocode/update/version.dart';

import 'update_fakes.dart';

void main() {
  const policy = UpdateUrlPolicy(custom: true);
  const good =
      'https://github.com/jiah0231/baocode/releases/download/custom-v1.7.3+24/BaoCode-1.7.3-setup.exe';
  test('custom app fails closed when its public key is absent', () {
    if (CustomUpdateChannel.enabled &&
        !CustomUpdateChannel.validPublicKey(CustomUpdateChannel.publicKey)) {
      expect(platformUpdates(updatesDirectory: '.'), isNull);
    }
  });
  test('build selects an independent fixed authority and key', () {
    if (!CustomUpdateChannel.enabled) return;
    expect(defaultManifestUrl, CustomUpdateChannel.manifestUrl);
    expect(updatePublicKey, CustomUpdateChannel.publicKey);
    expect(
      UpdateUrlPolicy.forManifest(Uri.parse('http://localhost/override'))
          .allows(Uri.parse('http://localhost/evil.exe')),
      isFalse,
    );
  });
  test('custom updates cannot be made mandatory by an unsigned field', () {
    final manifest = UpdateManifest.fromJson({
      'version': '9.0.0',
      'minimumVersion': '8.0.0',
      'platforms': {
        'windows-x64': {
          'url': good,
          'size': 100,
          'sha256': 'a' * 64,
          'signature': base64.encode(List.filled(64, 1)),
        },
      },
    }, policy: policy);
    final service = UpdateService(
      current: AppVersion.parse('1.0.0'),
      platform: 'windows-x64',
      backend: FakeBackend(''),
      installer: FakeInstaller(),
    );
    addTearDown(service.dispose);
    expect(
      service.isMandatory(
        UpdateRelease(
          manifest: manifest,
          platform: 'windows-x64',
          asset: manifest.assetFor('windows-x64')!,
        ),
      ),
      !CustomUpdateChannel.enabled,
    );
  });
  test(
    'custom backend rejects manifest override before making a request',
    () async {
      final backend = IoUpdateBackend(directory: '.', customChannel: true);
      await expectLater(
        backend.fetchManifest(Uri.parse('http://127.0.0.1/not-allowed')),
        throwsA(isA<HttpException>()),
      );
    },
  );
  test(
    'redirects allow only HTTPS release CDN without credentials or port',
    () {
      expect(
        CustomUpdateChannel.allowsRedirect(
          Uri.parse(
            'https://release-assets.githubusercontent.com/github-production-release-asset/a?sig=1',
          ),
        ),
        isTrue,
      );
      for (final url in [
        'http://release-assets.githubusercontent.com/a',
        'https://user@release-assets.githubusercontent.com/a',
        'https://release-assets.githubusercontent.com:444/a',
        'https://release-assets.githubusercontent.com.evil.test/a',
        'https://127.0.0.1/a',
        'https://github.com/other/repo',
      ]) {
        expect(
          CustomUpdateChannel.allowsRedirect(Uri.parse(url)),
          isFalse,
          reason: url,
        );
      }
    },
  );
  test(
    'fork assets require exact HTTPS repository and versioned Setup path',
    () {
      expect(policy.allows(Uri.parse(good)), isTrue);
      expect(
        policy.allows(
          Uri.parse(good.replaceFirst('-setup.exe', '-setup-arm64.exe')),
        ),
        isTrue,
      );
      for (final bad in [
        good.replaceFirst('https:', 'http:'),
        good.replaceFirst('github.com', 'github.com.evil.test'),
        good.replaceFirst('github.com', 'user@github.com'),
        good.replaceFirst('github.com', 'github.com:8443'),
        good.replaceFirst('jiah0231', 'baocode-dev'),
        good.replaceFirst('baocode/releases', 'another/releases'),
        good.replaceFirst('custom-v1.7.3+24', 'latest'),
        good.replaceFirst('custom-v1.7.3+24', '..'),
        good.replaceFirst('BaoCode-1.7.3-setup.exe', '%2e%2e%2fescape.exe'),
        good.replaceFirst(
          'BaoCode-1.7.3-setup.exe',
          'BaoCode-1.7.3-setup.exe%5cevil',
        ),
        '$good?redirect=evil',
        '$good#fragment',
        'https://dl.baocode.dev/releases/BaoCode-setup.exe',
      ]) {
        expect(policy.allows(Uri.parse(bad)), isFalse, reason: bad);
      }
    },
  );
  test('custom manifest never grants all of github.com or upstream origin', () {
    final selected = UpdateUrlPolicy.forManifest(
      Uri.parse(CustomUpdateChannel.manifestUrl),
    );
    expect(selected.allows(Uri.parse(good)), isTrue);
    expect(
      selected.allows(
        Uri.parse(
          'https://github.com/other/repo/releases/download/v1/setup.exe',
        ),
      ),
      isFalse,
    );
    expect(
      selected.allows(Uri.parse('https://baocode.dev/update.exe')),
      isFalse,
    );
  });
  test('missing or malformed key cannot enable the custom updater', () {
    expect(CustomUpdateChannel.validPublicKey(''), isFalse);
    expect(CustomUpdateChannel.validPublicKey('not-base64'), isFalse);
    expect(
      CustomUpdateChannel.validPublicKey(base64.encode(List.filled(31, 0))),
      isFalse,
    );
    expect(
      CustomUpdateChannel.validPublicKey(base64.encode(List.filled(32, 1))),
      isTrue,
    );
  });
}
