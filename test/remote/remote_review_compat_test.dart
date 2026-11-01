import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bao_remote/client.dart';
import 'package:bao_remote/review.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late StreamController<String> outgoing, incoming;
  late RpcPeer app, server;
  late RemoteClient client;
  late Map<String, Uint8List> blobs;
  late Map<String, Object?> files;
  late List<String> calls;
  String? saved;
  var modern = false;
  var sequence = 0;

  setUp(() {
    outgoing = StreamController();
    incoming = StreamController();
    app = RpcPeer(incoming.stream, outgoing.add);
    server = RpcPeer(outgoing.stream, incoming.add);
    client = RemoteClient(app);
    blobs = {};
    files = {};
    calls = [];
    saved = null;
    modern = false;
    sequence = 0;
    server.handlers[RemoteProtocol.reviewOpen] = (params, _) {
      // Protocol 9 requires root, unlike the upstream ledger-only server.
      expect((params as Map)['root'], '/project');
      return {'id': 7, 'root': '/project', if (modern) 'ledgerVersion': 4};
    };
    server.handlers[RemoteProtocol.reviewCall] = (params, _) {
      final request = params as Map;
      expect(request['id'], 7);
      final method = request['method'] as String;
      final args = request['args'] as Map;
      calls.add(method);
      switch (method) {
        case 'take':
        case 'current':
          expect((args['path'] as String).startsWith('/'), isTrue);
          return files[args['path']];
        case 'read':
          return encodeBytes(blobs[(args['blob'] as List)[1]]!);
        case 'store':
          final id = (++sequence).toRadixString(16).padLeft(40, '0');
          blobs[id] = decodeBytes(args['bytes']);
          return [args['mode'], id];
        case 'restore':
          files[args['path'] as String] = args['blob'];
          return null;
        case 'write':
          expect((args['path'] as String).startsWith('/'), isTrue);
          return null;
        case 'merge':
          // The protocol-9 shape takes path/from/to, not mine/from/to.
          if (!modern) throw StateError('Legacy merge RPC must not be called');
          expect(args['mine'], isA<List>());
          return encodeBytes(utf8.encode('modern merged'));
        case 'lineCounts':
          // Protocol 9 takes tree ids and returns a map per path.
          if (!modern) throw StateError('Legacy counts RPC must not be called');
          expect(args['from'], isA<List>());
          return [2, 1];
        case 'load':
          return saved;
        case 'save':
          expect(args['blobs'], isA<List>());
          saved = args['data'] as String;
          return null;
        case 'forget':
          saved = null;
          return null;
      }
      throw StateError('Unexpected RPC $method');
    };
  });

  tearDown(() async {
    app.close();
    server.close();
    await outgoing.close();
    await incoming.close();
  });

  Future<ReviewBlob> put(ReviewStore store, String text) =>
      store.store(Uint8List.fromList(utf8.encode(text)), mode: '100644');

  test(
    'protocol 9 keeps other edits in a three-way undo, without changed RPCs',
    () async {
      final store = (await client.openReview('/project'))!;
      final base = await put(store, '1\n2\n3\n');
      final agent = await put(store, '1\ntwo\n3\n');
      final current = await put(store, '1\ntwo\nTHREE\n');
      files['/project/a'] = current.toJson();
      expect(await store.current('/project/a'), current);
      expect(await store.take('/project/a'), current);
      expect(await store.lineCounts(base, agent), (added: 1, removed: 1));
      expect(await store.lineCounts(null, base), (added: 3, removed: 0));
      expect(
        utf8.decode((await store.merge(current, agent, base))!),
        '1\n2\nTHREE\n',
      );
      final overlapping = await put(store, '1\nOTHER\n3\n');
      expect(await store.merge(overlapping, agent, base), isNull);
      await store.restore('/project/a', current, root: '/project');
      expect(files['/project/a'], current.toJson());
      expect(calls, isNot(contains('merge')));
      expect(calls, isNot(contains('lineCounts')));
    },
  );

  test(
    'v3 migration makes paths absolute and preserves server SHA1 blobs',
    () async {
      final store = (await client.openReview('/project'))!;
      final before = await put(store, 'before');
      final after = await put(store, 'after');
      final old = saved = jsonEncode({
        'version': 3,
        'entries': {
          'src/a': {
            'base': before.toJson(),
            'after': after.toJson(),
            'shared': true,
          },
        },
        'unseen': [
          {'path': 'other', 'added': 1, 'removed': 0},
        ],
      });
      final migrated = jsonDecode((await store.load('s'))!) as Map;
      expect(migrated['version'], 4);
      expect(migrated['entries']['/project/src/a']['base'], before.toJson());
      expect(migrated['entries']['/project/src/a']['conflict'], isTrue);
      expect(migrated['entries']['/project/src/a']['legacyShared'], isTrue);
      expect(migrated['unseen'][0]['path'], '/project/other');
      expect(saved, old); // Loading never replaces the old saved ledger.
      await store.save('s', jsonEncode(migrated), blobs: [before, after]);
      expect(jsonDecode(saved!)['version'], 4);
    },
  );

  test(
    'failed legacy migration cannot overwrite or forget original ledger',
    () async {
      final store = (await client.openReview('/project'))!;
      final old = saved = jsonEncode({
        'version': 3,
        'entries': {
          'a': {
            'base': ['100644', 'missing'],
          },
        },
        'unseen': [],
      });
      await expectLater(store.load('s'), throwsA(anything));
      expect(
        () => store.save('s', '{}', blobs: []),
        throwsA(isA<ReviewUnavailable>()),
      );
      expect(() => store.forget('s'), throwsA(isA<ReviewUnavailable>()));
      expect(saved, old);
      expect(calls, isNot(contains('save')));
      expect(calls, isNot(contains('forget')));
    },
  );

  test('ledgerVersion 4 uses new RPC shapes unchanged', () async {
    modern = true;
    final store = (await client.openReview('/project'))!;
    final blob = await put(store, 'x');
    expect(await store.lineCounts(blob, blob), (added: 2, removed: 1));
    expect(
      utf8.decode((await store.merge(blob, blob, blob))!),
      'modern merged',
    );
    expect(calls, containsAll(['merge', 'lineCounts']));
  });
}
