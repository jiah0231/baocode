import 'dart:async';

import 'package:bao_remote/claude.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/codex/codex_catalog.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/remote/remote_claude.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReadOnlyServer implements CodexTransport {
  _ReadOnlyServer({this.fail = false});
  final bool fail;
  final methods = <String>[];
  final requests = <Map<String, Object?>>[];
  final _messages = StreamController<Map<String, Object?>>();
  final _exit = Completer<void>();
  bool closed = false;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;
  @override
  Future<void> get exited => _exit.future;
  @override
  void write(Map<String, Object?> request) {
    final method = request['method'] as String;
    methods.add(method);
    if (method == 'initialize') {
      _messages.add({'id': request['id'], 'result': <String, Object?>{}});
      return;
    }
    // Any runtime resume/start is a regression, even if no turn was sent.
    expect(method, 'thread/turns/list');
    final params = (request['params'] as Map).cast<String, Object?>();
    requests.add(params);
    if (fail) {
      _messages.add({'id': request['id'], 'error': {'message': 'Unavailable'}});
      return;
    }
    final older = params['cursor'] == 'older';
    _messages.add({
      'id': request['id'],
      'result': {
        'data': [
          {
            'id': older ? 'old-turn' : 'new-turn',
            'items': [
              {'id': 'u', 'type': 'userMessage', 'content': [
                {'type': 'text', 'text': older ? 'old question' : 'question'},
                {'type': 'image', 'url': 'not included'},
              ]},
              {'id': 'r', 'type': 'reasoning', 'summary': ['private reasoning']},
              {'id': 't', 'type': 'commandExecution', 'aggregatedOutput': 'tool output'},
              {'id': 'a', 'type': 'agentMessage', 'text': older ? 'old answer' : 'answer'},
            ],
          },
        ],
        'nextCursor': older ? null : 'older',
      },
    });
  }

  @override
  void close() {
    closed = true;
    unawaited(_messages.close());
    _exit.complete();
  }
}

SessionRecord _session() => SessionRecord(
  id: 'chosen', title: 'Selected session', cwd: '/project',
  updatedAt: DateTime(2026),
);

void main() {
  test('Codex catalog pages persisted text without target resume or turn', () async {
    final servers = <_ReadOnlyServer>[];
    final catalog = CodexCatalog(startServer: (location) async {
      expect(location, '/project');
      final server = _ReadOnlyServer();
      servers.add(server);
      return server;
    });
    final first = await catalog.readTextPage(_session());
    expect(first.messages.map((m) => m.role), ['user', 'assistant']);
    expect(first.messages.map((m) => m.text), ['question', 'answer']);
    expect(first.nextCursor, 'older');
    final old = await catalog.readTextPage(_session(), cursor: first.nextCursor);
    expect(old.messages.map((m) => m.text), ['old question', 'old answer']);
    expect(old.nextCursor, isNull);
    for (final server in servers) {
      expect(server.methods, ['initialize', 'thread/turns/list']);
      expect(server.requests.single['threadId'], 'chosen');
      expect(server.requests.single['limit'], 30);
      expect(server.closed, isTrue);
    }
  });

  test('Codex history failure is surfaced and server closes', () async {
    final server = _ReadOnlyServer(fail: true);
    final catalog = CodexCatalog(startServer: (_) async => server);
    await expectLater(catalog.readTextPage(_session()), throwsA(isA<CodexUnavailable>()));
    expect(server.closed, isTrue);
    expect(server.methods, ['initialize', 'thread/turns/list']);
  });

  test('Claude storage pager returns prose only and passes cursor', () async {
    final cursors = <String?>[];
    final catalog = ClaudeCatalog(readPage: (session, {required turns, before}) async {
      expect(session.id, 'chosen');
      expect(turns, 30);
      cursors.add(before);
      return ClaudeHistoryPage([
        {'type': 'system', 'message': {'content': 'not source prose'}},
        {'type': 'user', 'uuid': 'u', 'message': {'content': 'question'}},
        {'type': 'assistant', 'uuid': 'a', 'message': {'content': [
          {'type': 'thinking', 'thinking': 'private'},
          {'type': 'tool_use', 'name': 'Bash'},
          {'type': 'text', 'text': before == null ? 'answer' : 'older answer'},
        ]}},
        {'type': 'user', 'message': {'content': [
          {'type': 'tool_result', 'content': 'tool output'},
        ]}},
      ], earlier: before == null ? 'old' : null);
    });
    final first = await catalog.readTextPage(_session());
    expect(first.messages.map((m) => m.text), ['question', 'answer']);
    expect(first.messages.map((m) => m.id), ['u', 'a']);
    final older = await catalog.readTextPage(_session(), cursor: first.nextCursor);
    expect(older.messages.last.text, 'older answer');
    expect(older.nextCursor, isNull);
    expect(cursors, [null, 'old']);
  });
}
