import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'review_store.dart';

/// Reads the previous, Git-backed v3 ledgers without changing their refs,
/// files or configuration. All project parts must import before publishing
/// the new session; the original repositories remain available for recovery.
Future<({String data, List<ReviewBlob> blobs})?> importLegacyReview(
  String checkpoints,
  String session,
  Future<ReviewBlob> Function(Uint8List bytes, String mode) keep,
) async {
  final folder = Directory(checkpoints);
  if (!await folder.exists()) return null;
  final entries = <String, Object?>{};
  final unseen = <String, Object?>{};
  final blobs = <ReviewBlob>[];
  var found = false;
  final ref = 'refs/baocode/sessions/${_legacyName(session)}';
  for (final entity in await folder.list(followLinks: false).toList()) {
    if (entity is! Directory) continue;
    final description = File(p.join(entity.path, 'description'));
    final head = File(p.join(entity.path, 'HEAD'));
    if (!await description.exists() || !await head.exists()) continue;
    final text = await description.readAsString();
    const prefix = 'Snapshots of ';
    const suffix = ", for reviewing agents' changes.\n";
    if (!text.startsWith(prefix) || !text.endsWith(suffix)) continue;
    final root = text.substring(prefix.length, text.length - suffix.length);
    if (!p.isAbsolute(root)) {
      throw const ReviewUnavailable(
        'The old review has no absolute project path.',
      );
    }
    Future<ProcessResult> git(List<String> args) => Process.run(
      'git',
      ['--git-dir', entity.path, ...args],
      stdoutEncoding: null,
      stderrEncoding: utf8,
    );
    final listed = await git(['for-each-ref', '--format=%(refname)', ref]);
    if (listed.exitCode != 0) {
      throw const ReviewUnavailable(
        'The old review repository could not be read.',
      );
    }
    if (!const LineSplitter()
        .convert(utf8.decode(listed.stdout as List<int>))
        .contains(ref)) {
      continue;
    }
    final commit = await git(['cat-file', 'commit', ref]);
    if (commit.exitCode != 0) {
      throw const ReviewUnavailable(
        'The old review session could not be read.',
      );
    }
    final body = utf8.decode(commit.stdout as List<int>);
    final separator = body.indexOf('\n\n');
    if (separator < 0) {
      throw const ReviewUnavailable('The old review session is incomplete.');
    }
    final json = jsonDecode(body.substring(separator + 2));
    if (json is! Map || json['version'] != 3 || json['entries'] is! Map) {
      throw const ReviewUnavailable(
        'The old review format cannot be migrated safely.',
      );
    }
    found = true;
    String absolute(String path) =>
        p.normalize(p.isAbsolute(path) ? path : p.join(root, path));
    Future<Object?> convert(Object? value) async {
      if (value == null) return null;
      final blob = ReviewBlob.fromJson(value);
      if (blob == null || !RegExp(r'^[0-9a-f]{40,64}$').hasMatch(blob.oid)) {
        throw const ReviewUnavailable('An old review blob is invalid.');
      }
      final read = await git(['cat-file', 'blob', blob.oid]);
      if (read.exitCode != 0) {
        throw const ReviewUnavailable(
          'An old review blob is missing; the original ledger was preserved.',
        );
      }
      final imported = await keep(
        Uint8List.fromList(read.stdout as List<int>),
        blob.mode,
      );
      blobs.add(imported);
      return imported.toJson();
    }

    for (final item in (json['entries'] as Map).entries) {
      if (item.key is! String || item.value is! Map) {
        throw const ReviewUnavailable('An old review entry is invalid.');
      }
      final key = absolute(item.key as String);
      final entry = item.value as Map;
      final converted = {
        'base': await convert(entry['base']),
        'after': await convert(entry['after']),
        'conflict': entry['conflict'] == true || entry['shared'] == true,
        'legacyShared': entry['shared'] == true,
      };
      if (entries.containsKey(key) &&
          jsonEncode(entries[key]) != jsonEncode(converted)) {
        throw const ReviewUnavailable(
          'Old project reviews disagree about a file; their ledgers were preserved.',
        );
      }
      entries[key] = converted;
    }
    for (final item in (json['unseen'] as List? ?? const [])) {
      if (item is! Map ||
          item['path'] is! String ||
          item['added'] is! int ||
          item['removed'] is! int) {
        throw const ReviewUnavailable(
          'An old untracked review entry is invalid.',
        );
      }
      final key = absolute(item['path'] as String);
      unseen[key] = {
        'path': key,
        'added': item['added'],
        'removed': item['removed'],
      };
    }
  }
  if (!found) return null;
  return (
    data: jsonEncode({
      'version': 4,
      'entries': entries,
      'unseen': unseen.values.toList(),
    }),
    blobs: blobs,
  );
}

String _legacyName(String session) {
  if (RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9._-]*$').hasMatch(session) &&
      !session.endsWith('.lock')) {
    return session;
  }
  var hash = 0xcbf29ce4 << 32 | 0x84222325;
  for (final byte in utf8.encode(session)) {
    hash ^= byte;
    hash *= 0x100000001b3;
  }
  String half(int bits) => bits.toRadixString(16).padLeft(8, '0');
  return 'h${half(hash >>> 32)}${half(hash & 0xFFFFFFFF)}';
}
