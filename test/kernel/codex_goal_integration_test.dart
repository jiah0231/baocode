import 'dart:async';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _goal([String status = 'active']) => {
  'threadId': 'th',
  'objective': 'Fix the tests',
  'status': status,
  'createdAt': 1700000000,
  'tokensUsed': 20,
  'timeUsedSeconds': 4,
};

void main() {
  late _GoalServer server;
  late CodexKernel kernel;
  late List<KernelEvent> events;
  setUp(() {
    server = _GoalServer();
    kernel = CodexKernel.withTransport(MockKernels.codex, server);
    events = [];
    kernel.events.listen(events.add);
  });
  tearDown(() => kernel.dispose());

  test('goal command is RPC control; adopts genuine automatic turns', () async {
    kernel.send(const KernelTurn(id: 'set', text: '/goal Fix the tests'));
    await pumpEventQueue();
    expect(server.methods, contains('thread/goal/set'));
    expect(server.methods, isNot(contains('turn/start')));
    expect(
      events.whereType<GoalReported>().last.goal!.condition,
      'Fix the tests',
    );
    // Native goal lifecycle can start a turn without turn/start from the UI.
    server.notify('turn/started', {
      'threadId': 'foreign',
      'turn': {'id': 'bad'},
    });
    expect(events.whereType<TurnStarted>(), isEmpty);
    server.notify('turn/started', {
      'threadId': 'th',
      'turn': {'id': 'auto'},
    });
    expect(events.whereType<TurnStarted>(), hasLength(1));
    server.notify('turn/completed', {
      'threadId': 'th',
      'turn': {'id': 'auto', 'status': 'completed'},
    });
    expect(events.whereType<TurnEnded>(), hasLength(1));
    expect(events.whereType<GoalReported>().last.goal!.state, GoalState.active);
    // A late thread-level goal notification is valid after its turn ends.
    server.notify('thread/goal/updated', {
      'threadId': 'th',
      'turnId': 'auto',
      'goal': _goal('complete'),
    });
    expect(events.whereType<GoalReported>().last.goal!.state, GoalState.met);
    kernel.send(const KernelTurn(id: 'clear', text: '/goal clear'));
    await pumpEventQueue();
    expect(events.whereType<GoalReported>().last.goal, isNull);
  });

  test(
    'unsupported goals report an error but ordinary chat keeps working',
    () async {
      server.unsupported = true;
      kernel.send(const KernelTurn(id: 'set', text: '/goal Fix the tests'));
      await pumpEventQueue();
      expect(
        events
            .whereType<ItemUpserted>()
            .map((e) => e.item)
            .whereType<NoticeItem>(),
        isNotEmpty,
      );
      expect(kernel.health.status, KernelHealthStatus.ready);
      kernel.send(const KernelTurn(id: 'normal', text: 'Hello'));
      await pumpEventQueue();
      expect(server.methods, contains('turn/start'));
    },
  );

  test(
    'native goal turn starting during resume receives pending input by steer',
    () async {
      kernel.dispose();
      server = _GoalServer()..nativeOnResume = true;
      kernel = CodexKernel.withTransport(
        MockKernels.codex,
        server,
        context: KernelContext(
          resume: SessionRecord(
            id: 'th',
            title: 'Test',
            updatedAt: DateTime(2026),
            cwd: '/project',
          ),
        ),
      );
      events = [];
      kernel.events.listen(events.add);
      kernel.send(
        const KernelTurn(id: 'pending', text: 'Add this requirement'),
      );
      await pumpEventQueue();
      expect(server.methods, contains('turn/steer'));
      expect(server.methods, isNot(contains('turn/start')));
      final params =
          server.written.firstWhere(
                (m) => m['method'] == 'turn/steer',
              )['params']
              as Map;
      expect(params['expectedTurnId'], 'native-resume');
      expect(
        params['input'],
        contains(equals({'type': 'text', 'text': 'Add this requirement'})),
      );
    },
  );

  test('first goal and ordinary message create only one thread', () async {
    kernel.send(const KernelTurn(id: 'goal', text: '/goal Fix the tests'));
    kernel.send(const KernelTurn(id: 'normal', text: 'Hello'));
    await pumpEventQueue();
    expect(server.methods.where((m) => m == 'thread/start'), hasLength(1));
    expect(server.methods, contains('thread/goal/set'));
    expect(server.methods, contains('turn/start'));
  });

  test('resuming a thread restores the native goal snapshot', () async {
    kernel.dispose();
    server = _GoalServer()..stored = _goal('paused');
    kernel = CodexKernel.withTransport(
      MockKernels.codex,
      server,
      context: KernelContext(
        resume: SessionRecord(
          id: 'th',
          title: 'Test',
          updatedAt: DateTime(2026),
          cwd: '/project',
        ),
      ),
    );
    events = [];
    kernel.events.listen(events.add);
    kernel.send(const KernelTurn(id: 'show', text: '/goal status'));
    await pumpEventQueue();
    expect(server.methods, contains('thread/resume'));
    expect(
      events.whereType<GoalReported>().last.goal!.lastReason,
      contains('paused'),
    );
    server.notify('thread/goal/cleared', {'threadId': 'th'});
    expect(events.whereType<GoalReported>().last.goal, isNull);
  });
}

class _GoalServer implements CodexTransport {
  final _out = StreamController<Map<String, Object?>>.broadcast(sync: true);
  final _exited = Completer<void>();
  final written = <Map<String, Object?>>[];
  Map<String, Object?>? stored;
  bool unsupported = false;
  bool nativeOnResume = false;
  Iterable<Object?> get methods => written.map((e) => e['method']);
  @override
  Stream<Map<String, Object?>> get messages => _out.stream;
  @override
  Future<void> get exited => _exited.future;
  void notify(String method, Map<String, Object?> params) =>
      _out.add({'method': method, 'params': params});
  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    final method = message['method'];
    if (method == null) return;
    if (unsupported && '$method'.startsWith('thread/goal/')) {
      scheduleMicrotask(
        () => _out.add({
          'id': message['id'],
          'error': {'code': -32601, 'message': 'method not found'},
        }),
      );
      return;
    }
    final result = switch (method) {
      'thread/start' || 'thread/resume' => {
        'thread': {'id': 'th', 'turns': []},
      },
      'thread/goal/set' => {'goal': stored = _goal()},
      'thread/goal/get' => {'goal': stored},
      'thread/goal/clear' => {'cleared': true},
      'turn/start' => {
        'turn': {'id': 'normal'},
      },
      _ => <String, Object?>{},
    };
    scheduleMicrotask(() {
      _out.add({'id': message['id'], 'result': result});
      if (method == 'thread/resume' && nativeOnResume) {
        scheduleMicrotask(
          () => notify('turn/started', {
            'threadId': 'th',
            'turn': {'id': 'native-resume'},
          }),
        );
      }
    });
  }

  @override
  void close() {
    if (_exited.isCompleted) return;
    unawaited(_out.close());
    _exited.complete();
  }
}
