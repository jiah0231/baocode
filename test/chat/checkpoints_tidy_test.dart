@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baocode/chat/review/review_store_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late String checkpoints;
  final long = DateTime.now().subtract(const Duration(days: 60));

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('baocode_tidy_');
    checkpoints = p.join(await temp.resolveSymbolicLinks(), 'checkpoints');
  });

  tearDown(() => temp.delete(recursive: true));

  Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

  File blobFile(String oid) =>
      File(p.join(checkpoints, 'blobs', oid.substring(0, 2), oid.substring(2)));

  File sessionFile(String name) =>
      File(p.join(checkpoints, 'sessions', '$name.json'));

  /// Session [name], saved [long] ago with [blobs], by another run of the
  /// app.
  void saveLongAgo(String name, List<String> blobs) {
    final file = sessionFile(name)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'data': 'old', 'blobs': blobs}));
    file.setLastModifiedSync(long);
  }

  test('drops the sessions not saved for a month and the blobs only they '
      'kept, and runs once a day', () async {
    final store = BlobReviewStore.open(checkpoints);
    final kept = await store.store(bytes('kept'), mode: '100644');
    final dropped = await store.store(bytes('dropped'), mode: '100644');
    final fresh = await store.store(bytes('fresh'), mode: '100644');
    await store.save('recent', 'data', blobs: [kept]);
    saveLongAgo('old', [dropped.oid]);
    blobFile(kept.oid).setLastModifiedSync(long);
    blobFile(dropped.oid).setLastModifiedSync(long);

    await BlobReviewStore.tidy(checkpoints);
    expect(await store.load('recent'), 'data');
    expect(jsonDecode(sessionFile('old').readAsStringSync())['data'], '');
    expect(blobFile(kept.oid).existsSync(), isTrue);
    expect(blobFile(dropped.oid).existsSync(), isFalse);
    // Taken just now: a conversation at work may not have saved it yet.
    expect(blobFile(fresh.oid).existsSync(), isTrue);

    // Not again the same day.
    saveLongAgo('older', const []);
    await BlobReviewStore.tidy(checkpoints);
    expect(sessionFile('older').existsSync(), isTrue);
    await BlobReviewStore.tidy(
      checkpoints,
      now: DateTime.now().add(const Duration(days: 2)),
    );
    expect(jsonDecode(sessionFile('older').readAsStringSync())['data'], '');
  });

  test('preserves old Git repositories for ledger recovery', () async {
    final store = BlobReviewStore.open(checkpoints);
    final blob = await store.store(bytes('a'), mode: '100644');
    await store.save('s', 'data', blobs: [blob]);
    final repository = Directory(p.join(checkpoints, 'project-0123abcd'))
      ..createSync(recursive: true);
    File(p.join(repository.path, 'HEAD')).writeAsStringSync('ref\n');

    await BlobReviewStore.tidy(checkpoints);
    expect(repository.existsSync(), isTrue);
    expect(await store.load('s'), 'data');
    expect(await store.read(blob), bytes('a'));
  });

  test('clearing leaves only what the conversations open keep', () async {
    final store = BlobReviewStore.open(checkpoints);
    final held = await store.store(bytes('held'), mode: '100644');
    await store.save('held', 'data', blobs: [held]);
    final other = await store.store(bytes('other'), mode: '100644');
    saveLongAgo('closed', [other.oid]);
    blobFile(other.oid).setLastModifiedSync(long);
    expect(await BlobReviewStore.sizeOf(checkpoints), greaterThan(0));

    await BlobReviewStore.clear(checkpoints);
    expect(jsonDecode(sessionFile('closed').readAsStringSync())['data'], '');
    expect(blobFile(other.oid).existsSync(), isFalse);
    expect(await store.load('held'), 'data');
    expect(await store.read(held), bytes('held'));
  });

  test('a session no longer kept goes when cleared', () async {
    final store = BlobReviewStore.open(checkpoints);
    final blob = await store.store(bytes('gone'), mode: '100644');
    await store.save('s', 'data', blobs: [blob]);
    await store.forget('s');
    blobFile(blob.oid).setLastModifiedSync(long);
    await BlobReviewStore.clear(checkpoints);
    expect(await store.load('s'), isNull);
    expect(blobFile(blob.oid).existsSync(), isFalse);
  });

  test('a missing folder is left be', () async {
    await BlobReviewStore.tidy(p.join(temp.path, 'none'));
    await BlobReviewStore.clear(p.join(temp.path, 'none'));
    expect(Directory(p.join(temp.path, 'none')).existsSync(), isFalse);
  });
  test('malformed fresh and expired ledgers and their possible blobs stay recoverable', () async {
    final store = BlobReviewStore.open(checkpoints);
    final blob = await store.store(bytes('recovery'), mode: '100644');
    blobFile(blob.oid).setLastModifiedSync(long);
    for (final name in ['fresh-broken', 'old-broken']) {
      sessionFile(name)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{partial ledger');
    }
    sessionFile('old-broken').setLastModifiedSync(long);
    await BlobReviewStore.tidy(checkpoints);
    expect(sessionFile('fresh-broken').readAsStringSync(), '{partial ledger');
    expect(sessionFile('old-broken').readAsStringSync(), '{partial ledger');
    expect(await store.read(blob), bytes('recovery'));
    await BlobReviewStore.clear(checkpoints);
    expect(sessionFile('fresh-broken').readAsStringSync(), '{partial ledger');
    expect(sessionFile('old-broken').readAsStringSync(), '{partial ledger');
    expect(await store.read(blob), bytes('recovery'));
  });
}
