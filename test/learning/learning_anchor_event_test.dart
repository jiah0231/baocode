import 'dart:async';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/claude_code/claude_code_translator.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:flutter_test/flutter_test.dart';

class _Server implements CodexTransport {
  final _messages = StreamController<Map<String, Object?>>.broadcast(
    sync: true,
  );
  final _exit = Completer<void>();

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;
  @override
  Future<void> get exited => _exit.future;
  void push(Map<String, Object?> message) => _messages.add(message);

  @override
  void write(Map<String, Object?> message) {
    final result = switch (message['method']) {
      'thread/start' => {
        'thread': {'id': 'thread'},
      },
      'turn/start' => {
        'turn': {'id': 'turn'},
      },
      null => null,
      _ => <String, Object?>{},
    };
    if (result != null) {
      scheduleMicrotask(() => push({'id': message['id'], 'result': result}));
    }
  }

  @override
  void close() {
    _messages.close();
    if (!_exit.isCompleted) _exit.complete();
  }
}

void main() {
  test('FileEdited remains compatible without an explicit anchor', () {
    const event = FileEdited(
      1,
      FileChange(path: 'a.dart', added: 1, removed: 0),
    );
    expect(event.sourceItemId, isNull);
  });

  test(
    'Codex anchors repeated-path changes to their exact diff item IDs',
    () async {
      final server = _Server();
      final kernel = CodexKernel.withTransport(MockKernels.codex, server);
      addTearDown(kernel.dispose);
      final events = <KernelEvent>[];
      kernel.events.listen(events.add);
      kernel.send(const KernelTurn(id: 'request', text: 'synthetic edit'));
      await pumpEventQueue();
      for (final id in ['first', 'second']) {
        final item = {
          'type': 'fileChange',
          'id': id,
          'status': 'completed',
          'changes': [
            {'path': 'lib/same.dart', 'diff': '@@ -1 +1 @@\n-old\n+new'},
            {'path': 'test/same.dart', 'diff': '@@ -1 +1 @@\n-old\n+new'},
          ],
        };
        server.push({
          'method': 'item/started',
          'params': {'item': item},
        });
        expect(events.whereType<FileEdited>().length, id == 'first' ? 0 : 2);
        server.push({
          'method': 'item/completed',
          'params': {'item': item},
        });
      }
      final edits = events.whereType<FileEdited>().toList();
      expect(edits.map((e) => e.sourceItemId), [
        'first:0',
        'first:1',
        'second:0',
        'second:1',
      ]);
      for (final edit in edits) {
        final diffs = events.whereType<ItemUpserted>().where(
          (e) => e.id == edit.sourceItemId,
        );
        expect(diffs.last.item, isA<CodeDiffItem>());
        expect(diffs.last.seq, lessThan(edit.seq));
      }
    },
  );

  test('Codex failed or declined edits never confirm a file change', () async {
    final server = _Server();
    final kernel = CodexKernel.withTransport(MockKernels.codex, server);
    addTearDown(kernel.dispose);
    final events = <KernelEvent>[];
    kernel.events.listen(events.add);
    kernel.send(const KernelTurn(id: 'request', text: 'synthetic edit'));
    await pumpEventQueue();
    for (final status in ['failed', 'declined', 'inProgress']) {
      server.push({
        'method': 'item/completed',
        'params': {
          'item': {
            'type': 'fileChange',
            'id': status,
            'status': status,
            'changes': [
              {'path': 'same.dart', 'diff': '@@ -1 +1 @@\n-old\n+new'},
            ],
          },
        },
      });
    }
    expect(events.whereType<FileEdited>(), isEmpty);
    expect(
      events.whereType<ItemUpserted>().where((e) => e.item is CodeDiffItem),
      hasLength(3),
    );
    server.push({
      'method': 'item/completed',
      'params': {
        'item': {
          'type': 'fileChange',
          'id': 'legacy',
          'changes': [
            {'path': 'same.dart', 'diff': '@@ -1 +1 @@\n-old\n+new'},
          ],
        },
      },
    });
    expect(events.whereType<FileEdited>().single.sourceItemId, 'legacy:0');
  });

  test(
    'Claude repeated writes keep exact operation provenance, not filenames',
    () {
      final events = <KernelEvent>[];
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: events.add,
        nextSeq: () => ++seq,
      );
      void write(String id, {bool failed = false, bool patch = true}) {
        translator.translate({
          'type': 'assistant',
          'message': {
            'id': 'message-$id',
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': id,
                'name': 'Write',
                'input': {'file_path': 'lib/same.dart', 'content': 'new\n'},
              },
            ],
          },
        });
        translator.translate({
          'type': 'user',
          'message': {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': id,
                'is_error': failed,
                'content': failed ? 'denied' : 'ok',
              },
            ],
          },
          if (patch)
            'tool_use_result': {
              'type': 'create',
              'filePath': 'lib/same.dart',
              'content': 'new\n',
            },
        });
      }

      write('first');
      write('second');
      write('failed', failed: true);
      final edits = events.whereType<FileEdited>().toList();
      expect(edits, hasLength(2));
      expect(edits.map((e) => e.sourceItemId), ['first', 'second']);
      for (final edit in edits) {
        final diff = events.whereType<ItemUpserted>().lastWhere(
          (e) => e.id == edit.sourceItemId,
        );
        expect(diff.item, isA<CodeDiffItem>());
        expect(diff.seq, lessThan(edit.seq));
      }
      write('no-patch', patch: false);
      expect(events.whereType<FileEdited>().last.sourceItemId, isNull);
      final count = events.whereType<FileEdited>().length;
      translator.replaying = true;
      write('historical');
      expect(events.whereType<FileEdited>(), hasLength(count));
    },
  );
}
