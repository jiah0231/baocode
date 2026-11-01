// Local preparation only. Does not generate keys, upload, or publish anything.
// BAOCODE_CUSTOM_UPDATE_SIGNING_KEY_FILE: existing base64 Ed25519 seed file.
// BAOCODE_CUSTOM_UPDATE_KEY: public key embedded in the matching app build.
// dart run tool/custom_release_manifest.dart <version> <setup.exe> <latest.json>
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:baocode/update/custom_update_channel.dart';
import 'package:baocode/update/update_manifest.dart';
import 'package:baocode/update/update_signature.dart';
import 'package:baocode/update/version.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3 || args.length > 4) {
    throw ArgumentError(
      'Expected version, setup.exe, output latest.json, optional previous manifest',
    );
  }
  final version = AppVersion.parse(args[0]);
  final root = File.fromUri(Platform.script).parent.parent;
  final pubspec = File('${root.path}/pubspec.yaml').readAsStringSync();
  final declared = RegExp(
    r'^version:\s*(\S+)',
    multiLine: true,
  ).firstMatch(pubspec)?.group(1);
  if (version != currentAppVersion || declared != '$version') {
    throw StateError('Manifest version must match both app version files');
  }
  if (args.length == 4) {
    final previous = UpdateManifest.parse(
      await File(args[3]).readAsString(),
      policy: const UpdateUrlPolicy(custom: true),
    );
    if (version <= previous.version) {
      throw StateError(
        'New release must be newer than the custom stable channel',
      );
    }
  }
  final installer = File(args[1]);
  final publicKey = Platform.environment['BAOCODE_CUSTOM_UPDATE_KEY'] ?? '';
  final keyFile =
      Platform.environment['BAOCODE_CUSTOM_UPDATE_SIGNING_KEY_FILE'];
  if (!CustomUpdateChannel.validPublicKey(publicKey) || keyFile == null) {
    throw StateError(
      'An existing private key file and matching public key are required',
    );
  }
  final seed = (await File(keyFile).readAsString()).trim();
  if (UpdateSignature.publicKeyOf(seed) != publicKey) {
    throw StateError('Signing key does not match the app build public key');
  }
  final name = installer.uri.pathSegments.last;
  final url = Uri.parse(
    '${CustomUpdateChannel.releases}/download/custom-v$version/$name',
  );
  if (!CustomUpdateChannel.allowsAsset(url)) {
    throw ArgumentError('Expected a BaoCode Windows Setup filename');
  }
  final platform = name.endsWith('-setup-arm64.exe')
      ? 'windows-arm64'
      : 'windows-x64';
  final size = await installer.length();
  final hash = '${await sha256.bind(installer.openRead()).first}';
  final payload = UpdateSignature.payload(
    version: '$version',
    platform: platform,
    size: size,
    sha256: hash,
  );
  final signature = UpdateSignature.sign(payload: payload, seed: seed);
  if (!UpdateSignature.verify(
    payload: payload,
    signature: signature,
    publicKey: publicKey,
  )) {
    throw StateError('Signature self-check failed');
  }
  final manifest = {
    'version': '$version',
    'pubDate': DateTime.now().toUtc().toIso8601String(),
    'notes': {'zh': '定制版更新：保留性能优化和 Codex 功能。确认重启后安装。'},
    'platforms': {
      platform: UpdateAsset(
        url: url,
        size: size,
        sha256: hash,
        signature: signature,
      ).toJson(),
    },
  };
  UpdateManifest.fromJson(
    manifest,
    policy: const UpdateUrlPolicy(custom: true),
  ).assetFor(platform);
  await File(
    args[2],
  ).writeAsString('${const JsonEncoder.withIndent('  ').convert(manifest)}\n');
}
