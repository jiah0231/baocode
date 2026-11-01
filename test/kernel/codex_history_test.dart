import 'dart:async';
import 'dart:io';

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
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('codex-history-');
    server = _HistoryServer('${directory.path}/config.toml');
    kernel = CodexKernel.withTransport(
      MockKernels.codex,
      server,
      context: KernelContext(
        resume: SessionRecord(
          id: 'th',
          title: 'History',
          updatedAt: DateTime(2026),
          cwd: directory.path,
        ),
      ),
    );
    events = [];
    kernel.events.listen(events.add);
  });
  tearDown(() async {
    kernel.dispose();
    await directory.delete(recursive: true);
  });

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
    final ready = _untilHealth(kernel, KernelHealthStatus.ready);
    kernel.prepare();
    await ready;
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
    final disposed = Completer<void>();
    kernel.events.listen((event) {
      if (event is ItemUpserted && event.id == 'item-0') {
        Timer.run(() {
          server.completeItem('item-79', 'must not emit');
          beforeDispose = events.length;
          kernel.dispose();
          disposed.complete();
        });
      }
    });
    kernel.prepare();
    await disposed.future.timeout(const Duration(seconds: 5));
    // Let the already-scheduled replay batch resume and observe cancellation.
    await Future<void>.delayed(Duration.zero);
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
    final ready = _untilHealth(kernel, KernelHealthStatus.ready);
    runZonedGuarded<void>(() {
      kernel.prepare();
    }, (error, _) => failures.add(error));
    await ready;
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
    final failed = _untilHealth(kernel, KernelHealthStatus.failed);
    kernel.prepare();
    await failed;
    expect(events.whereType<ItemUpserted>(), hasLength(80));
    final complete = events.whereType<ItemCompleted>().single;
    expect((complete.item as AssistantTextItem).text, 'last text');
    expect(kernel.loadingHistory, isFalse);
    expect(kernel.health.status, KernelHealthStatus.failed);
  });
}

Future<void> _untilHealth(CodexKernel kernel, KernelHealthStatus status) async {
  if (kernel.health.status == status) return;
  final reached = Completer<void>();
  final subscription = kernel.events.listen((_) {
    if (kernel.health.status == status && !reached.isCompleted) {
      reached.complete();
    }
  });
  try {
    await reached.future.timeout(const Duration(seconds: 5));
  } finally {
    await subscription.cancel();
  }
}

class _HistoryServer implements CodexTransport {
  _HistoryServer(this.configPath);

  final String configPath;
  final _messages = StreamController<Map<String, Object?>>.broadcast(sync: true);
  final _exited = Completer<void>();

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;
  @override
  Future<void> get exited => _exited.future;

  @override
  void write(Map<String, Object?> message) {
    final result = switch (message['method']) {
      'config/read' => <String, Object?>{
        'config': <String, Object?>{},
        'layers': [
          {
            'name': {'type': 'user', 'file': configPath},
          },
        ],
      },
      'thread/resume' => <String, Object?>{
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
      },
      _ => <String, Object?>{},
    };
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
