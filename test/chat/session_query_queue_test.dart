import 'dart:async';
import 'dart:convert';

import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/session_query.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _Server implements CodexTransport {
  final controller = StreamController<Map<String, Object?>>.broadcast();
  final changes = StreamController<void>.broadcast();
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

  Future<void> started(int count) async {
    if (starts.length < count) {
      await changes.stream.firstWhere((_) => starts.length >= count)
          .timeout(const Duration(seconds: 10));
    }
    await Future<void>(() {});
  }

  @override
  void write(Map<String, Object?> message) {
    if (message['method'] == null) return;
    final method = message['method'];
    if (method == 'turn/start') {
      starts.add(message);
      changes.add(null);
    }
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

  for (final finish in [false, true]) {
    test('real Codex queued selection is host-turn bound and revoked on '
        '${finish ? 'finish' : 'stop'}', () async {
      final server = _Server();
      late final KernelDescriptor descriptor;
      late CodexKernel kernel;
      descriptor = KernelDescriptor(
        id: 'codex', label: 'Codex', icon: const IconData(0xe001), description: '',
        create: (context) => kernel = CodexKernel.withTransport(
          descriptor, server, context: context,
        ),
      );
      var reads = 0;
      final service = SessionQueryService(read: (id) async {
        reads++;
        return SessionQuerySnapshot(
          targetId: id, title: 'Claude target', kernel: 'Claude Code', messages: const [
            SessionQueryMessage(index: 0, role: 'assistant', text: 'Queued context'),
          ],
        );
      })..register();
      final session = ChatSession(
        kernel: descriptor, kernels: [descriptor], historyCount: 0,
        kernelContext: const KernelContext(cwd: '/project'),
        openReview: (_, {session}) async => null,
      )
        ..sessionQueries = service
        ..canQuerySession = (id) => id == 'claude-code:target';
      String? activeTurn;
      final events = kernel.events.listen((event) {
        if (event case TurnStarted(:final turnId)) activeTurn = turnId;
        if (event case TurnEnded(:final turnId) when turnId == activeTurn) {
          activeTurn = null;
        }
      });
      addTearDown(() async {
        session.dispose();
        service.dispose();
        await events.cancel();
        await server.changes.close();
      });
      final tool = ClaudeSdkTools.called('mcp__baocode__session_query')!;
      // This represents host dispatch context, not model-controlled arguments.
      Future<Object> query({String? turn}) => tool.run({
        'session_id': 'claude-code:target',
      }, ClaudeSdkCall(cwd: '/project', sessionId: 'source', turnId: turn ?? activeTurn));
      session.send(const ComposerMessage(text: 'First request'));
      await server.started(1);
      final firstTurn = activeTurn;
      expect(firstTurn, isNotNull);
      session.send(const ComposerMessage(
        text: 'Read selected context', sessionMentions: ['claude-code:target'],
      ));
      expect(session.queued, hasLength(1));
      final queuedTurn = session.queued.single.$1;
      expect(activeTurn, firstTurn);
      await expectLater(query(), throwsStateError);
      await expectLater(query(turn: queuedTurn), throwsStateError);
      expect(reads, 0, reason: 'A queued grant cannot be borrowed by the active turn.');
      session.stop();
      await server.started(2);
      expect(activeTurn, queuedTurn);
      expect(jsonEncode(server.starts.last), isNot(matches(r'sq_[0-9a-f]{64}')));
      expect(jsonEncode(server.starts.last), isNot(contains('capability=')));
      expect(await query(), contains('Queued context'));
      await expectLater(query(turn: firstTurn), throwsStateError);
      final ended = kernel.events.firstWhere(
        (event) => event is TurnEnded && event.turnId == queuedTurn,
      );
      if (finish) {
        server.controller.add({'method': 'turn/completed', 'params': {
          'threadId': 'source', 'turn': {'id': 'turn-2', 'status': 'completed'},
        }});
      } else {
        session.stop();
      }
      await ended.timeout(const Duration(seconds: 10));
      await Future<void>(() {});
      await expectLater(query(turn: queuedTurn), throwsStateError);
      expect(reads, 1);
    });
  }
}
