import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../protocol.dart';
import '../review/review_store.dart';
import '../review/line_diff.dart' as diff;
import '../rpc/rpc_peer.dart';

/// [ReviewStore] of the remote host: its checkpoints there (in the
/// server's data folder), every call a request.
class RemoteReviewStore implements ReviewStore {
  RemoteReviewStore(
    this._peer,
    this._id, {
    required this.root,
    this.legacy = false,
  });

  /// The server's canonical project root; SSH servers use POSIX paths.
  final String root;
  final bool legacy;
  final Set<String> _failedLoads = {};

  final RpcPeer _peer;
  final int _id;

  Future<Object?> _call(
    String method, [
    Map<String, Object?> args = const {},
  ]) => _peer.request(RemoteProtocol.reviewCall, {
    'id': _id,
    'method': method,
    'args': args,
  });

  static ReviewBlob? _blob(Object? json) => ReviewBlob.fromJson(json);

  @override
  Future<ReviewBlob?> take(String path) async =>
      _blob(await _call('take', {'path': path}));

  @override
  Future<ReviewBlob?> current(String path) async =>
      _blob(await _call('current', {'path': path}));

  @override
  Future<Uint8List> read(ReviewBlob blob) async =>
      decodeBytes(await _call('read', {'blob': blob.toJson()}));

  @override
  Future<ReviewBlob> store(Uint8List bytes, {required String mode}) async =>
      _blob(await _call('store', {'bytes': encodeBytes(bytes), 'mode': mode}))!;

  @override
  Future<void> restore(String path, ReviewBlob? blob, {String? root}) =>
      _call('restore', {'path': path, 'blob': blob?.toJson(), 'root': root});

  @override
  Future<void> write(String path, Uint8List bytes) =>
      _call('write', {'path': path, 'bytes': encodeBytes(bytes)});

  @override
  Future<Uint8List?> merge(
    ReviewBlob mine,
    ReviewBlob from,
    ReviewBlob to,
  ) async {
    if (legacy) {
      if (mine.isLink || from.isLink || to.isLink) return null;
      final a = await read(mine), b = await read(from), c = await read(to);
      return Isolate.run(() => diff.merge3(a, b, c));
    }
    final merged = await _call('merge', {
      'mine': mine.toJson(),
      'from': from.toJson(),
      'to': to.toJson(),
    });
    return merged == null ? null : decodeBytes(merged);
  }

  @override
  Future<({int added, int removed})?> lineCounts(
    ReviewBlob? from,
    ReviewBlob? to,
  ) async {
    if (legacy) {
      if (from == to) return (added: 0, removed: 0);
      final a = from == null ? null : await read(from);
      final b = to == null ? null : await read(to);
      return Isolate.run(() => diff.lineCounts(a, b));
    }
    return switch (await _call('lineCounts', {
      'from': from?.toJson(),
      'to': to?.toJson(),
    })) {
      [final int added, final int removed] => (added: added, removed: removed),
      _ => null,
    };
  }

  @override
  Future<String?> load(String session) async {
    try {
      final data = await _call('load', {'session': session}) as String?;
      if (!legacy || data == null) {
        _failedLoads.remove(session);
        return data;
      }
      final json = jsonDecode(data);
      if (json is! Map<String, dynamic> ||
          (json['version'] != 3 && json['version'] != 4)) {
        throw const ReviewUnavailable('Unsupported saved review ledger');
      }
      if (json['version'] == 4) {
        _failedLoads.remove(session);
        return data;
      }
      final entries = json['entries'];
      final unseen = json['unseen'];
      if (entries is! Map<String, dynamic> || unseen is! List) {
        throw const ReviewUnavailable('Invalid saved review ledger');
      }
      String absolute(String path) => p.posix.normalize(
        p.posix.isAbsolute(path) ? path : p.posix.join(root, path),
      );
      final migrated = <String, Object?>{};
      final verified = <ReviewBlob>{};
      for (final entry in entries.entries) {
        final value = entry.value;
        if (value is! Map<String, dynamic>) {
          throw const ReviewUnavailable('Invalid saved review entry');
        }
        for (final key in ['base', 'after']) {
          final raw = value[key];
          if (raw == null) continue;
          final blob = ReviewBlob.fromJson(raw);
          if (blob == null) {
            throw const ReviewUnavailable('Invalid saved review blob');
          }
          if (verified.add(blob)) await read(blob);
        }
        final path = absolute(entry.key);
        if (migrated.containsKey(path)) {
          throw const ReviewUnavailable('Conflicting saved review paths');
        }
        migrated[path] = {
          'base': value['base'],
          'after': value['after'],
          'conflict': value['conflict'] == true || value['shared'] == true,
          if (value['shared'] == true) 'legacyShared': true,
        };
      }
      final migratedUnseen = <Object?>[];
      for (final change in unseen) {
        if (change is! Map<String, dynamic> ||
            change['path'] is! String ||
            change['added'] is! int ||
            change['removed'] is! int) {
          throw const ReviewUnavailable('Invalid saved untracked review');
        }
        migratedUnseen.add({
          ...change,
          'path': absolute(change['path'] as String),
        });
      }
      _failedLoads.remove(session);
      // Keep the Git blob ids: the legacy server still owns their storage.
      // Do not save during conversion; failure leaves the original untouched.
      return jsonEncode({
        'version': 4,
        'entries': migrated,
        'unseen': migratedUnseen,
      });
    } on Object {
      _failedLoads.add(session);
      rethrow;
    }
  }

  void _checkLoaded(String session) {
    if (_failedLoads.contains(session)) {
      throw const ReviewUnavailable('The saved review could not be migrated');
    }
  }

  @override
  Future<void> save(
    String session,
    String data, {
    required Iterable<ReviewBlob> blobs,
  }) {
    _checkLoaded(session);
    return _call('save', {
      'session': session,
      'data': data,
      'blobs': [for (final blob in blobs) blob.toJson()],
    });
  }

  @override
  Future<void> forget(String session) {
    _checkLoaded(session);
    return _call('forget', {'session': session});
  }
}
