import 'dart:async';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _HistoryServer server;
  late CodexKernel kernel;
  late List<KernelEvent> events;

  setUp(() {
    server = _HistoryServer();
    kernel = CodexKernel.withTransport(
      MockKernels.codex,
      server,
      context: KernelContext(
        resume: SessionRecord(
          id: 'th',
          title: 'History',
          updatedAt: DateTime(2026),
          cwd: '/project',
        ),
      ),
    );
    events = [];
    kernel.events.listen(events.add);
  });
  tearDown(() => kernel.dispose());

  test('large history yields and keeps live updates after snapshots', () async {
    int? countAtYield;
    kernel.events.listen((event) {
      if (event is ItemUpserted && event.id == 'item-0') {
        Timer.run(() {
          countAtYield = events.whereType<ItemUpserted>().length;
          server.completeItem('item-79', 'new text');
        });
      }
    });
    kernel.prepare();
    await pumpEventQueue(times: 100);
    expect(countAtYield, inExclusiveRange(0, 80));
    final snapshots = events.whereType<ItemUpserted>().toList();
    expect(snapshots.map((e) => e.id), [
      for (var i = 0; i < 80; i++) 'item-$i',
    ]);
    final complete = events.whereType<ItemCompleted>().single;
    expect(complete.id, 'item-79');
    expect((complete.item as AssistantTextItem).text, 'new text');
    expect(complete.seq, greaterThan(snapshots.last.seq));
    expect(kernel.loadingHistory, isFalse);
  });

  test('dispose between batches cancels replay and queued notifications', () async {
    int? beforeDispose;
    kernel.events.listen((event) {
      if (event is ItemUpserted && event.id == 'item-0') {
        Timer.run(() {
          server.completeItem('item-79', 'must not emit');
          beforeDispose = events.length;
          kernel.dispose();
        });
      }
    });
    kernel.prepare();
    await pumpEventQueue(times: 100);
    expect(beforeDispose, isNotNull);
    expect(events.length, beforeDispose);
    expect(events.whereType<ItemUpserted>().length, lessThan(80));
    expect(events.whereType<ItemCompleted>(), isEmpty);
  });

  test('a malformed queued notification does not leave replay fenced', () async {
    final failures = <Object>[];
    kernel.events.listen((event) {
      if (event is ItemUpserted && event.id == 'item-0') {
        Timer.run(() {
          server.completeItem('bad', 42);
          server.completeItem('item-79', 'after malformed');
        });
      }
    });
    await runZonedGuarded<Future<void>>(() async {
      kernel.prepare();
      await pumpEventQueue(times: 100);
    }, (error, _) => failures.add(error));
    expect(failures, hasLength(1));
    expect(kernel.loadingHistory, isFalse);
    final complete = events.whereType<ItemCompleted>().single;
    expect((complete.item as AssistantTextItem).text, 'after malformed');
  });

  test('exit during replay drains history and queued updates first', () async {
    kernel.events.listen((event) {
      if (event is ItemUpserted && event.id == 'item-0') {
        Timer.run(() {
          server.completeItem('item-79', 'last text');
          server.exit();
        });
      }
    });
    kernel.prepare();
    await pumpEventQueue(times: 100);
    expect(events.whereType<ItemUpserted>(), hasLength(80));
    final complete = events.whereType<ItemCompleted>().single;
    expect((complete.item as AssistantTextItem).text, 'last text');
    expect(kernel.loadingHistory, isFalse);
    expect(kernel.health.status, KernelHealthStatus.failed);
  });
}

class _HistoryServer implements CodexTransport {
  final _messages = StreamController<Map<String, Object?>>.broadcast(sync: true);
  final _exited = Completer<void>();

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;
  @override
  Future<void> get exited => _exited.future;

  @override
  void write(Map<String, Object?> message) {
    final result = message['method'] == 'thread/resume'
        ? <String, Object?>{
            'thread': {
              'id': 'th',
              'turns': [
                {
                  'id': 'past',
                  'items': [
                    for (var i = 0; i < 80; i++)
                      {'id': 'item-$i', 'type': 'agentMessage', 'text': 'old $i'},
                  ],
                },
              ],
            },
          }
        : <String, Object?>{};
    scheduleMicrotask(() {
      if (!_messages.isClosed) {
        _messages.add({'id': message['id'], 'result': result});
      }
    });
  }

  void completeItem(String id, Object text) => _messages.add({
    'method': 'item/completed',
    'params': {
      'threadId': 'th',
      'item': {'id': id, 'type': 'agentMessage', 'text': text},
    },
  });

  void exit() {
    if (_exited.isCompleted) return;
    _messages.add(CodexExit.message(0, ''));
    _exited.complete();
    unawaited(_messages.close());
  }

  @override
  void close() {
    if (!_exited.isCompleted) _exited.complete();
    unawaited(_messages.close());
  }
}
