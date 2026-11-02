import 'dart:async';
import 'dart:convert';

import 'package:baocode/chat/session_query.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/codex/codex_app_tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SessionQueryService service;
  late List<String> reads;
  late DateTime now;
  late String token;
  late String? caller;
  late String? activeTurn;
  late Future<SessionQuerySnapshot?> Function(String) reader;

  SessionQuerySnapshot snapshot(String id, {int count = 12}) => SessionQuerySnapshot(
    targetId: id,
    title: 'Target conversation',
    kernel: id.startsWith('codex:') ? 'Codex' : 'Claude Code',
    busy: true,
    hasEarlierHistory: true,
    olderCursor: 'page0',
    messages: List.generate(count, (i) => SessionQueryMessage(
      index: i,
      role: i.isEven ? 'user' : 'assistant',
      text: 'message $i ${i.isEven ? 'needle' : 'other'}',
    )),
  );

  Future<Map<String, Object?>> invoke({
    String? target,
    String? session = 'source',
    String? turn = 'turn',
    String cwd = '/source',
    Map<String, Object?> extra = const {},
    String? query,
    int? before,
    bool? older,
    Future<void>? cancelled,
  }) async {
    final answer = await ClaudeSdkTools.handle({
      'id': 1,
      'method': 'tools/call',
      'params': {
        'name': SessionQueryService.toolName,
        'arguments': {
          'session_id': target ?? 'codex:target',
          'query': ?query,
          'before': ?before,
          'older': ?older,
          ...extra,
        },
      },
    }, ClaudeSdkCall(cwd: cwd, sessionId: session, turnId: turn, cancelled: cancelled));
    return (answer['result'] as Map).cast<String, Object?>();
  }

  Map<String, dynamic> payload(Map<String, Object?> result) =>
      jsonDecode(((result['content'] as List).first as Map)['text'] as String)
          as Map<String, dynamic>;

  setUp(() {
    reads = [];
    now = DateTime.utc(2026);
    caller = 'source';
    activeTurn = 'turn';
    reader = (id) async => snapshot(id);
    service = SessionQueryService(now: () => now, read: (id) {
      reads.add(id);
      return reader(id);
    })..register();
    token = service.grant(['codex:target', 'claude-code:target'],
      callerTurnId: 'turn', isActive: () => activeTurn == 'turn', callerCwd: '/source', callerSessionId: () => caller);
  });
  tearDown(() => service.dispose());

  test('oversized page clearly reports unavailable within-page text', () async {
    service.dispose();
    service = SessionQueryService(read: (id) async => SessionQuerySnapshot(
      targetId: id, title: 'Large page', kernel: 'Codex',
      messages: [SessionQueryMessage(index: 0, role: 'assistant',
          text: List.filled(200001, 'x').join())],
    ))..register();
    service.grant(['codex:target'], callerTurnId: 'turn', isActive: () => activeTurn == 'turn', callerCwd: '/source', callerSessionId: () => 'source');
    final output = await ClaudeSdkTools.called('mcp__baocode__session_query')!.run({
      'session_id': 'codex:target',
    }, const ClaudeSdkCall(cwd: '/source', sessionId: 'source', turnId: 'turn'));
    final result = jsonDecode(output as String) as Map;
    expect(result['truncated_window'], true);
    expect(result['coverage_warning'], contains('cannot be recovered'));
  });

  test('Claude route reads selected Codex snapshot with attribution and pages', () async {
    final result = payload(await invoke());
    expect(result['source']['kernel'], 'Codex');
    expect(result['target_busy'], true);
    expect(result['mode'], 'read_only_history');
    expect(result['has_earlier_history'], true);
    expect(result['messages'], hasLength(8));
    expect(result['next_before'], 4);
    final older = payload(await invoke(before: 4));
    expect(older['messages'], hasLength(4));
    expect(reads, ['codex:target']);
  });

  test('literal query filters and kernel-qualified IDs stay distinct', () async {
    final result = payload(await invoke(target: 'claude-code:target', query: 'NEEDLE'));
    expect(result['source']['kernel'], 'Claude Code');
    expect(result['messages'], hasLength(6));
    expect(reads, ['claude-code:target']);
  });

  test('Codex dynamic tool route can retrieve selected Claude history', () async {
    final bridge = CodexAppTools('/source');
    addTearDown(bridge.cancel);
    expect((await bridge.specs()).map((tool) => tool['name']), contains('session_query'));
    final answer = await bridge.call({
      'threadId': 'source',
      'turnId': 'turn',
      'callId': 'query',
      'namespace': null,
      'tool': 'session_query',
      'arguments': {'session_id': 'claude-code:target'},
    }, threadId: 'source', turnId: 'turn');
    expect(answer['success'], true);
    expect(answer['contentItems'].toString(), contains('Claude Code'));
  });

  test('unselected, foreign and null caller denied before read', () async {
    expect((await invoke(target: 'codex:secret'))['isError'], true);
    expect((await invoke(target: 'codex:secret', extra: {'capability': token}))['isError'], true);
    expect((await invoke(session: 'other'))['isError'], true);
    expect((await invoke(session: null))['isError'], true);
    expect(reads, isEmpty);
  });

  test('schema and result need no model-visible authorization credential', () async {
    final tool = ClaudeSdkTools.called('mcp__baocode__session_query')!;
    expect((tool.inputSchema['properties'] as Map).keys,
      unorderedEquals(['session_id', 'query', 'before', 'older']));
    expect(tool.inputSchema['required'], ['session_id']);
    final result = await invoke();
    expect(result['isError'], isNull);
    expect(result.toString(), isNot(contains(token)));
  });

  test('persisted legacy capability is ignored and cannot replace host authorization', () async {
    for (final legacy in [token, 'invented', '', null, 123, {'turnId': 'turn'}]) {
      expect((await invoke(extra: {'capability': legacy}))['isError'], isNull);
      expect((await invoke(turn: null, extra: {'capability': legacy}))['isError'], true);
      expect((await invoke(session: 'other', extra: {'capability': legacy}))['isError'], true);
      expect((await invoke(cwd: '/other', extra: {'capability': legacy}))['isError'], true);
      expect((await invoke(target: 'codex:secret', extra: {'capability': legacy}))['isError'], true);
    }
    expect(reads, ['codex:target']);
    activeTurn = null;
    expect((await invoke(extra: {'capability': token}))['isError'], true);
  });

  test('missing, empty, stale and model-spoofed turn identity fail closed', () async {
    final missing = await invoke(turn: null);
    expect(missing['isError'], true);
    expect(missing.toString(), contains('no authenticated active source turn'));
    expect((await invoke(turn: ''))['isError'], true);
    expect((await invoke(turn: 'previous-turn'))['isError'], true);
    expect((await invoke(turn: 'next-unmentioned-turn'))['isError'], true);
    expect((await invoke(turn: null, extra: {'turnId': 'turn'}))['isError'], true);
    expect((await invoke(extra: {'sessionId': 'source'}))['isError'], true);
    expect(reads, isEmpty);
  });

  test('queued selection cannot enlarge the currently running turn grant', () async {
    final queuedToken = service.grant(['codex:queued'],
      callerTurnId: 'queued-turn', isActive: () => activeTurn == 'queued-turn',
      callerCwd: '/source', callerSessionId: () => caller);
    expect((await invoke(target: 'codex:queued'))['isError'], true);
    expect((await invoke(turn: 'queued-turn', target: 'codex:target'))['isError'], true);
    expect((await invoke())['isError'], isNull);
    expect((await invoke(turn: 'queued-turn', target: 'codex:queued'))['isError'], true);
    activeTurn = 'queued-turn';
    expect((await invoke(turn: 'queued-turn', target: 'codex:queued'))['isError'], isNull);
    service.revoke(token);
    expect((await invoke())['isError'], true);
    expect((await invoke(turn: 'queued-turn', target: 'codex:queued'))['isError'], isNull);
    service.revoke(queuedToken);
    expect((await invoke(turn: 'queued-turn', target: 'codex:queued'))['isError'], true);
    expect(reads, ['codex:target', 'codex:queued']);
  });

  test('ambiguous authenticated grants deny rather than union targets', () async {
    service.grant(['codex:other'],
      callerTurnId: 'turn', isActive: () => activeTurn == 'turn', callerCwd: '/source', callerSessionId: () => caller);
    final result = await invoke();
    expect(result['isError'], true);
    expect(result.toString(), contains('ambiguous source-turn selection'));
    expect(result.toString(), isNot(contains(token)));
    expect(reads, isEmpty);
  });

  test('owner dispatch matches trusted source context not a supplied secret', () async {
    final other = SessionQueryService(read: (id) async => snapshot(id))..register();
    addTearDown(other.dispose);
    other.grant(['codex:other'],
      callerTurnId: 'turn', isActive: () => activeTurn == 'turn', callerCwd: '/source', callerSessionId: () => 'other-source');
    expect((await invoke(target: 'codex:other'))['isError'], true);
    expect((await invoke(session: 'other-source', target: 'codex:other'))['isError'], isNull);
    expect((await invoke())['isError'], isNull);
    expect(reads, ['codex:target']);
  });

  test('new caller ID resolves dynamically but permission never follows another ID', () async {
    caller = null;
    expect((await invoke())['isError'], true);
    caller = 'source';
    expect((await invoke())['isError'], isNull);
    caller = 'replacement';
    expect((await invoke())['isError'], true);
  });

  test('revoke and expiry fail closed', () async {
    service.revoke(token);
    expect((await invoke())['isError'], true);
    token = service.grant(['codex:target'], callerTurnId: 'turn', isActive: () => activeTurn == 'turn', callerCwd: '/source', callerSessionId: () => caller);
    now = now.add(SessionQueryService.lifetime);
    expect((await invoke())['isError'], true);
    expect(reads, isEmpty);
  });

  test('pending reads cannot return after revocation', () async {
    final pending = Completer<SessionQuerySnapshot?>();
    reader = (_) => pending.future;
    final answer = invoke();
    await Future<void>.delayed(Duration.zero);
    service.revoke(token);
    pending.complete(snapshot('codex:target'));
    expect((await answer)['isError'], true);
  });

  test('inactive source turn is denied before reading with precise diagnostics', () async {
    activeTurn = null;
    now = now.add(SessionQueryService.lifetime);
    final result = await invoke();
    expect(result['isError'], true);
    expect(result.toString(), contains('source turn is no longer active'));
    expect(result.toString(), isNot(contains('expired')));
    expect(result.toString(), isNot(contains(token)));
    expect(reads, isEmpty);
  });

  test('turn switch during read rejects captured old caller without revoke', () async {
    final pending = Completer<SessionQuerySnapshot?>();
    reader = (_) => pending.future;
    final answer = invoke();
    await Future<void>.delayed(Duration.zero);
    activeTurn = 'replacement-turn';
    pending.complete(snapshot('codex:target'));
    final result = await answer;
    expect(result['isError'], true);
    expect(result.toString(), contains('source turn is no longer active'));
    expect(result.toString(), isNot(contains('Target conversation')));
  });

  test('cancel does not wait for a busy target', () async {
    final pending = Completer<SessionQuerySnapshot?>();
    reader = (_) => pending.future;
    final cancelled = Completer<void>();
    final answer = invoke(cancelled: cancelled.future);
    cancelled.complete();
    expect((await answer)['isError'], true);
    pending.complete(snapshot('codex:target'));
  });

  test('frozen snapshot, text limits, redaction and no tool/thinking history', () async {
    final messages = <SessionQueryMessage>[
      SessionQueryMessage(index: 0, role: 'assistant', text: 'quoted $token'),
      const SessionQueryMessage(index: 1, role: 'tool', text: 'secret tool data'),
      const SessionQueryMessage(index: 2, role: 'thinking', text: 'private thoughts'),
      SessionQueryMessage(index: 3, role: 'user', text: 'x' * 10000),
    ];
    reader = (id) async => SessionQuerySnapshot(
      targetId: id, title: 'Title', kernel: 'Codex', messages: messages);
    final first = payload(await invoke());
    messages.clear();
    final second = payload(await invoke());
    expect(second, first);
    expect(first['messages'], hasLength(2));
    expect(first.toString(), isNot(contains(token)));
    expect(first.toString(), isNot(contains('secret tool data')));
    expect(first['messages'].last['truncated'], true);
    expect((first['messages'].last['text'] as String).length, 2001);
  });

  test('missing or mismatched target never returns another source', () async {
    reader = (_) async => snapshot('codex:other');
    expect((await invoke())['isError'], true);
  });

  test('cwd binding and removed targets invalidate cached retrieval', () async {
    service.dispose();
    var available = true;
    service = SessionQueryService(
      read: (id) async => snapshot(id),
      isAvailable: (_) => available,
    )..register();
    token = service.grant(['codex:target'],
      callerTurnId: 'turn', isActive: () => activeTurn == 'turn', callerCwd: '/wrong', callerSessionId: () => 'source');
    expect((await invoke())['isError'], true);
    token = service.grant(['codex:target'],
      callerTurnId: 'turn', isActive: () => activeTurn == 'turn', callerCwd: '/source', callerSessionId: () => 'source');
    expect((await invoke())['isError'], isNull);
    available = false;
    expect((await invoke())['isError'], true);
  });

  test('query returns relevant excerpt from a long message', () async {
    reader = (id) async => SessionQuerySnapshot(
      targetId: id, title: 'Title', kernel: 'Codex', messages: [
        SessionQueryMessage(index: 0, role: 'assistant',
          text: '${'x' * 5000} requested detail ${'x' * 5000}'),
      ]);
    final result = payload(await invoke(query: 'requested detail'));
    expect(result['messages'].single['text'], contains('requested detail'));
    expect(result['messages'].single['start_character'], greaterThan(0));
  });

  test('deep history advances only selected target and accepts negative indexes', () async {
    service.dispose();
    var olderReads = 0;
    service = SessionQueryService(
      read: (id) async => snapshot(id),
      readOlder: (id, before) async {
        olderReads++;
        expect(before, 'page0');
        return SessionQuerySnapshot(targetId: id, title: 'Old', kernel: 'Codex',
          messages: const [
            SessionQueryMessage(index: -2, role: 'user', text: 'deep answer'),
            SessionQueryMessage(index: -1, role: 'assistant', text: 'old answer'),
          ]);
      },
    )..register();
    token = service.grant(['codex:target'], callerTurnId: 'turn', isActive: () => activeTurn == 'turn', callerCwd: '/source', callerSessionId: () => caller);
    expect((await invoke(target: 'codex:secret', older: true))['isError'], true);
    expect(olderReads, 0);
    final result = payload(await invoke(older: true, query: 'deep'));
    expect(result['messages'].single['text'], 'deep answer');
    expect(result['next_history_available'], false);
    final page = payload(await invoke(before: -1));
    expect(page['messages'].single['index'], -2);
    expect((await invoke(older: true))['isError'], true);
    expect(olderReads, 1);
  });

  test('failed reads are retryable and simultaneous older reads are coalesced', () async {
    var calls = 0;
    reader = (id) async {
      if (++calls == 1) throw StateError('transient');
      return snapshot(id);
    };
    expect((await invoke())['isError'], true);
    expect((await invoke())['isError'], isNull);
    expect(calls, 2);
    service.dispose();
    var olderCalls = 0;
    final pending = Completer<SessionQuerySnapshot?>();
    service = SessionQueryService(
      read: (id) async => snapshot(id),
      readOlder: (_, _) { olderCalls++; return pending.future; },
    )..register();
    token = service.grant(['codex:target'], callerTurnId: 'turn', isActive: () => activeTurn == 'turn', callerCwd: '/source', callerSessionId: () => caller);
    await invoke();
    final first = invoke(older: true);
    final second = invoke(older: true);
    await Future<void>.delayed(Duration.zero);
    expect(olderCalls, 1);
    pending.complete(SessionQuerySnapshot(targetId: 'codex:target', title: 'Old',
      kernel: 'Codex', messages: const []));
    expect((await first)['isError'], isNull);
    expect((await second)['isError'], isNull);
  });

  test('empty history pages retain their private cursor and can advance', () async {
    service.dispose();
    var attempts = 0;
    service = SessionQueryService(
      read: (id) async => SessionQuerySnapshot(
        targetId: id, title: 'Empty', kernel: 'Codex', messages: const [],
        hasEarlierHistory: true, olderCursor: 'opaque storage cursor'),
      readOlder: (id, cursor) async {
        expect(cursor, 'opaque storage cursor');
        if (++attempts == 1) throw StateError('retryable older read');
        return SessionQuerySnapshot(targetId: id, title: 'Old', kernel: 'Codex',
          messages: const [SessionQueryMessage(index: -1, role: 'user', text: 'deep')]);
      },
    )..register();
    token = service.grant(['codex:target'], callerTurnId: 'turn', isActive: () => activeTurn == 'turn', callerCwd: '/source', callerSessionId: () => caller);
    final first = payload(await invoke());
    expect(first['next_history_available'], true);
    expect(first.toString(), isNot(contains('opaque storage cursor')));
    expect((await invoke(older: true))['isError'], true);
    expect(payload(await invoke(older: true))['messages'].single['text'], 'deep');
  });

  test('grant target count is bounded', () {
    expect(() => service.grant(List.generate(9, (i) => '$i'),
      callerTurnId: 'turn', isActive: () => activeTurn == 'turn', callerCwd: '/source', callerSessionId: () => caller), throwsArgumentError);
  });

  test('disposing one workspace keeps another workspace tool registered', () async {
    final other = SessionQueryService(read: (id) async => snapshot(id))..register();
    other.dispose();
    expect((await invoke())['isError'], isNull);
  });
}
