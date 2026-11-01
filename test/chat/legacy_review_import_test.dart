@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/local.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late String checkpoints;
  late BlobReviewStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('baocode_legacy_review_');
    checkpoints = p.join(temp.path, 'checkpoints');
    store = BlobReviewStore.open(checkpoints);
  });
  tearDown(() => temp.delete(recursive: true));

  Future<String> git(String repo, List<String> args, {List<int>? input}) async {
    final process = await Process.start(
      'git',
      ['--git-dir', repo, ...args],
      environment: {
        'GIT_AUTHOR_NAME': 'Test',
        'GIT_AUTHOR_EMAIL': 'test@example.invalid',
        'GIT_COMMITTER_NAME': 'Test',
        'GIT_COMMITTER_EMAIL': 'test@example.invalid',
      },
    );
    if (input != null) process.stdin.add(input);
    await process.stdin.close();
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;
    expect(code, 0, reason: await errors);
    return (await output).trim();
  }

  Future<({String repo, String root, String before})> legacy(
    String name, {
    String session = 's',
    bool missingBlob = false,
  }) async {
    final root = p.join(temp.path, name);
    final repo = p.join(checkpoints, '$name-old');
    await Directory(repo).create(recursive: true);
    await git(repo, ['init', '--bare', '--template=']);
    await File(p.join(repo, 'description'))
        .writeAsString("Snapshots of $root, for reviewing agents' changes.\n");
    final before = await git(
      repo,
      ['hash-object', '-w', '--stdin'],
      input: [0, 255, 13, 10],
    );
    final after = await git(repo, [
      'hash-object',
      '-w',
      '--stdin',
    ], input: utf8.encode('after\r\n'));
    final data = jsonEncode({
      'version': 3,
      'entries': {
        'file.bin': {
          'base': ['100644', missingBlob ? '0' * 40 : before],
          'after': ['100644', after],
          'shared': true,
        },
        'deleted': {
          'base': ['100644', before],
          'after': null,
        },
      },
      'unseen': [
        {'path': 'untracked', 'added': 2, 'removed': 1},
      ],
    });
    final tree = await git(repo, ['mktree'], input: const []);
    final commit = await git(repo, [
      'commit-tree',
      tree,
    ], input: utf8.encode(data));
    await git(repo, ['update-ref', 'refs/baocode/sessions/$session', commit]);
    return (repo: repo, root: root, before: before);
  }

  test('imports every project part and preserves bytes, deletions and original repositories', () async {
    final a = await legacy('a');
    final b = await legacy('b');
    final imported = jsonDecode((await store.load('s'))!) as Map;
    expect(imported['version'], 4);
    final entries = imported['entries'] as Map;
    expect(entries.length, 4);
    for (final project in [a, b]) {
      final entry = entries[p.join(project.root, 'file.bin')] as Map;
      final blob = ReviewBlob.fromJson(entry['base'])!;
      expect(blob.oid.length, 64);
      expect(entry['legacyShared'], isTrue);
      expect(entry['conflict'], isTrue);
      expect(
        await store.read(ReviewBlob.fromJson(entry['after'])!),
        utf8.encode('after\r\n'),
      );
      expect(await store.read(blob), [0, 255, 13, 10]);
      expect(
        (entries[p.join(project.root, 'deleted')] as Map)['after'],
        isNull,
      );
      expect(Directory(project.repo).existsSync(), isTrue);
    }
    expect((imported['unseen'] as List).length, 2);
    await BlobReviewStore.tidy(checkpoints);
    expect(Directory(a.repo).existsSync(), isTrue);
  });

  test('a partial migration fails closed and does not publish or overwrite a session', () async {
    await legacy('good');
    final bad = await legacy('bad', missingBlob: true);
    await expectLater(store.load('s'), throwsA(isA<ReviewUnavailable>()));
    expect(
      File(p.join(checkpoints, 'sessions', 's.json')).existsSync(),
      isFalse,
    );
    await expectLater(
      store.save('s', 'replacement', blobs: const []),
      throwsA(isA<ReviewUnavailable>()),
    );
    await expectLater(store.forget('s'), throwsA(isA<ReviewUnavailable>()));
    // Repairing only the failed legacy ledger allows a fresh import retry.
    await legacy('bad');
    expect(await store.load('s'), isNotNull);
    expect(Directory(bad.repo).existsSync(), isTrue);
  });

  test(
    'new data wins, and forgetting cannot resurrect a legacy ledger after tidy',
    () async {
      await legacy('a');
      await store.save('s', 'new data', blobs: const []);
      expect(await store.load('s'), 'new data');
      await store.forget('s');
      expect(await store.load('s'), isNull);
      await BlobReviewStore.tidy(
        checkpoints,
        now: DateTime.now().add(const Duration(days: 90)),
      );
      expect(await store.load('s'), isNull);
    },
  );
  test(
    'concurrent loads share migration and a newer save or forget wins',
    () async {
      await legacy('a');
      final first = store.load('s');
      final second = store.load('s');
      expect(identical(first, second), isTrue);
      final saved = store.save('s', 'newer data', blobs: const []);
      expect(await first, isNotNull);
      await saved;
      expect(await store.load('s'), 'newer data');
      await legacy('b', session: 'other');
      final importing = store.load('other');
      final forgotten = store.forget('other');
      expect(await importing, isNotNull);
      await forgotten;
      expect(await store.load('other'), isNull);
    },
  );
}
