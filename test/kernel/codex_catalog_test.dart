import 'dart:async';

import 'package:baocode/kernel/codex/codex_catalog.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
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
