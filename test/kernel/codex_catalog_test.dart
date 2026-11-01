import 'dart:async';

import 'package:baocode/kernel/codex/codex_catalog.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/codex/codex_session_locations.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';

class _CatalogServer implements CodexTransport {
  _CatalogServer(this.page);
  final Map<String, Object?> Function(Map<String, Object?>) page;
  final _messages = StreamController<Map<String, Object?>>();
  final _exit = Completer<void>();
  final requests = <Map<String, Object?>>[];

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;
  @override
  Future<void> get exited => _exit.future;
  @override
  void write(Map<String, Object?> message) {
    final params = (message['params'] as Map).cast<String, Object?>();
    final result = message['method'] == 'thread/list'
        ? page(params)
        : <String, Object?>{};
    if (message['method'] == 'thread/list') requests.add(params);
    _messages.add({'id': message['id'], 'result': result});
  }

  @override
  void close() {
    _messages.close();
    _exit.complete();
  }
}

Map<String, Object?> _session(String id, {String originator = 'baocode'}) => {
  'id': id,
  'originator': originator,
  'cwd': '/project',
  'updatedAt': 100,
  'preview': id,
};

void main() {
  test(
    'relocation survives reopening, repeated moves, and merged history',
    () async {
      var saved = <String, Object?>{};
      CodexSessionLocations store() => CodexSessionLocations(
        read: () async => saved,
        write: (value) async {
          saved = value;
        },
      );
      final rows = [
        {..._session('old'), 'cwd': '/old', 'path': '/home/codex/old.jsonl'},
        {..._session('existing'), 'cwd': '/new'},
      ];
      CodexCatalog catalog() => CodexCatalog(
        locations: store(),
        startServer: (_) async => _CatalogServer(
          (params) => {
            'data': rows
                .where(
                  (row) => params['cwd'] == null || row['cwd'] == params['cwd'],
                )
                .toList(),
          },
        ),
      );
      expect(await catalog().moveSessions('/old', '/new'), 1);
      expect(await catalog().sessionsIn('/old'), isEmpty);
      var kept = await catalog().sessionsIn('/new');
      expect(kept.map((s) => s.id), containsAll(['old', 'existing']));
      expect(kept.firstWhere((s) => s.id == 'old').cwd, '/new');
      expect(
        kept.firstWhere((s) => s.id == 'old').path,
        '/home/codex/old.jsonl',
      );
      rows.add({..._session('fresh'), 'cwd': '/old'});
      expect((await catalog().sessionsIn('/old')).single.id, 'fresh');
      expect(await catalog().moveSessions('/new', '/third'), 2);
      kept = await catalog().sessionsIn('/third');
      expect(kept.map((s) => s.id), containsAll(['old', 'existing']));
      expect(kept.every((s) => s.cwd == '/third'), isTrue);
      expect(await catalog().sessionsIn('/new'), isEmpty);
      final projects = await catalog().projects();
      expect(projects.map((p) => p.path), containsAll(['/old', '/third']));
      expect(projects.map((p) => p.path), isNot(contains('/new')));
      // A different Codex home with the same ID/cwd is not the moved rollout.
      rows[0] = {...rows[0], 'path': '/another-home/old.jsonl'};
      expect(
        (await catalog().sessionsIn('/old')).map((s) => s.id),
        contains('old'),
      );
      expect(
        (await catalog().sessionsIn('/third')).map((s) => s.id),
        isNot(contains('old')),
      );
    },
  );

  test('failed persistence and unavailable Codex fail the move', () async {
    final catalog = CodexCatalog(
      locations: CodexSessionLocations(
        read: () async => {},
        write: (_) async => throw StateError('disk full'),
      ),
      startServer: (_) async => _CatalogServer(
        (_) => {
          'data': [_session('ours')],
        },
      ),
    );
    await expectLater(
      catalog.moveSessions('/project', '/new'),
      throwsStateError,
    );
    final offline = CodexCatalog(
      startServer: (_) async => throw const CodexUnavailable('offline'),
    );
    await expectLater(
      offline.moveSessions('/project', '/new'),
      throwsA(isA<CodexUnavailable>()),
    );
    expect(
      await offline.moveSessions('/claude-only-unlisted', '/elsewhere'),
      0,
    );
  });

  test('aliases preserve host boundary and can be removed on delete', () async {
    var saved = <String, Object?>{};
    final locations = CodexSessionLocations(
      read: () async => saved,
      write: (value) async {
        saved = value;
      },
    );
    SessionRecord session(String cwd) => SessionRecord(
      id: 'same',
      title: 't',
      updatedAt: DateTime(2026),
      cwd: cwd,
      path: '/rollout.jsonl',
    );
    await locations.move([session('ssh://one/old')], 'ssh://one/new');
    expect(
      CodexSessionLocations.apply(saved, session('ssh://one/old')).cwd,
      'ssh://one/new',
    );
    expect(
      CodexSessionLocations.apply(saved, session('ssh://two/old')).cwd,
      'ssh://two/old',
    );
    expect(CodexSessionLocations.apply(saved, session('/old')).cwd, '/old');
    await locations.remove('same', 'ssh://two/new');
    expect(saved, isNotEmpty);
    await locations.remove('same', 'ssh://one/new');
    expect(saved, isEmpty);
    final catalog = CodexCatalog(locations: locations);
    await expectLater(
      catalog.moveSessions('/old', 'ssh://one/new'),
      throwsArgumentError,
    );
  });

  test(
    'keeps paging beyond 2000 foreign sessions to BaoCode history',
    () async {
      final server = _CatalogServer((params) {
        final page = int.parse(params['cursor'] as String? ?? '0');
        return {
          'data': [
            if (page < 21)
              _session('foreign-$page', originator: 'codex_cli_rs'),
            if (page == 21) _session('ours'),
          ],
          'nextCursor': page < 21 ? '${page + 1}' : null,
        };
      });
      final catalog = CodexCatalog(startServer: (_) async => server);
      final sessions = await catalog.sessionsIn('/project');
      expect(sessions.map((s) => s.id), ['ours']);
      expect(server.requests, hasLength(22));
    },
  );

  test('stops cursor cycles and deduplicates overlapping pages', () async {
    final server = _CatalogServer(
      (params) => {
        'data': [_session('ours')],
        'nextCursor': params['cursor'] == 'a' ? 'b' : 'a',
      },
    );
    final catalog = CodexCatalog(startServer: (_) async => server);
    expect((await catalog.sessionsIn('/project')).map((s) => s.id), ['ours']);
    expect(server.requests, hasLength(3));
  });
}
