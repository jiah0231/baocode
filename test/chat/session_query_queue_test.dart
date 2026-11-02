import 'dart:async';
import 'dart:convert';

import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/session_query.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _Server implements CodexTransport {
  final controller = StreamController<Map<String, Object?>>.broadcast();
  final done = Completer<void>();
  final starts = <Map<String, Object?>>[];
  @override
  Stream<Map<String, Object?>> get messages => controller.stream;
  @override
  Future<void> get exited => done.future;
  @override
  void close() {
    unawaited(controller.close());
    if (!done.isCompleted) done.complete();
  }

  @override
  void write(Map<String, Object?> message) {
    if (message['method'] == null) return;
    final method = message['method'];
    if (method == 'turn/start') starts.add(message);
    final result = switch (method) {
      'initialize' => {'userAgent': 'baocode/0.166.0 (Windows)'},
      'thread/start' => {'thread': {'id': 'source'}},
      'turn/start' => {'turn': {'id': 'turn-${starts.length}'}},
      _ => <String, Object?>{},
    };
    scheduleMicrotask(() {
      if (!controller.isClosed) {
        controller.add({'id': message['id'], 'result': result});
      }
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real Codex stop starts queued selected request without revoking its grant', () async {
    final server = _Server();
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'codex', label: 'Codex', icon: const IconData(0xe001), description: '',
      create: (context) => CodexKernel.withTransport(descriptor, server, context: context),
    );
    final service = SessionQueryService(read: (id) async => SessionQuerySnapshot(
      targetId: id, title: 'Claude target', kernel: 'Claude Code', messages: const [
        SessionQueryMessage(index: 0, role: 'assistant', text: 'Queued context'),
      ],
    ))..register();
    final session = ChatSession(
      kernel: descriptor, kernels: [descriptor], historyCount: 0,
      kernelContext: const KernelContext(cwd: '/project'),
      openReview: (_, {session}) async => null,
    )
      ..sessionQueries = service
      ..canQuerySession = (id) => id == 'claude-code:target';
    addTearDown(() { session.dispose(); service.dispose(); });
    session.send(const ComposerMessage(text: 'First request'));
    await pumpEventQueue(times: 50);
    expect(server.starts, hasLength(1));
    session.send(const ComposerMessage(
      text: 'Read selected context', sessionMentions: ['claude-code:target'],
    ));
    expect(session.queued, hasLength(1));
    session.stop();
    await pumpEventQueue(times: 50);
    expect(server.starts, hasLength(2));
    final token = RegExp(r'sq_[0-9a-f]{64}')
        .firstMatch(jsonEncode(server.starts.last))!.group(0)!;
    final tool = ClaudeSdkTools.called('mcp__baocode__session_query')!;
    Future<Object> query() => tool.run({
      'capability': token, 'session_id': 'claude-code:target',
    }, const ClaudeSdkCall(cwd: '/project', sessionId: 'source'));
    expect(await query(), contains('Queued context'));
    server.controller.add({'method': 'turn/completed', 'params': {
      'threadId': 'source', 'turn': {'id': 'turn-2', 'status': 'completed'},
    }});
    await pumpEventQueue();
    await expectLater(query(), throwsStateError);
  });
}
