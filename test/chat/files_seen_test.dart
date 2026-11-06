import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';

/// A kernel whose events the test sends.
class _Kernel implements AgentKernel {
  _Kernel(this.descriptor, this.events);

  @override
  final KernelDescriptor descriptor;

  @override
  final Stream<KernelEvent> events;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Counts history visits without adding a production-only test hook.
class _CountedRead extends ToolCallItem {
  const _CountedRead(this.onRead) : super(kind: ToolKind.read, target: 'a');

  final VoidCallback onRead;

  @override
  String get path {
    onRead();
    return 'a.dart';
  }
}

final _root = p.absolute('files-seen-project');

String path(String name) => p.join(_root, name);

/// A session in a local project fed [events], as they come.
ChatSession _session(Stream<KernelEvent> events) {
  late final KernelDescriptor descriptor;
  descriptor = KernelDescriptor(
    id: 'test',
    label: 'Test',
    icon: Icons.abc,
    description: '',
    create: (context) => _Kernel(descriptor, events),
  );
  final session = ChatSession(
    kernel: descriptor,
    kernels: [descriptor],
    kernelContext: KernelContext(cwd: _root),
    historyCount: 0,
  );
  addTearDown(session.dispose);
  return session;
}

void main() {
  test('filesSeen is the same list while no file is new', () {
    final live = StreamController<KernelEvent>.broadcast(sync: true);
    addTearDown(live.close);
    final session = _session(live.stream);
    live.add(
      const ItemUpserted(
        1,
        'read',
        ToolCallItem(kind: ToolKind.read, target: 'a', path: 'a.dart'),
      ),
    );
    live.add(const ItemUpserted(2, 'say', AssistantTextItem('a')));
    final files = session.filesSeen;
    expect(files, [path('a.dart')]);
    live.add(const ItemUpserted(3, 'say', AssistantTextItem('ab')));
    live.add(
      ItemUpserted(
        4,
        'again',
        ToolCallItem(kind: ToolKind.read, target: 'a', path: path('a.dart')),
      ),
    );
    expect(session.filesSeen, same(files));
    live.add(
      const FileEdited(5, FileChange(path: 'b.dart', added: 1, removed: 0)),
    );
    expect(session.filesSeen, [path('a.dart'), path('b.dart')]);
  });

  test('streaming text does not rescan previously seen tools', () {
    final live = StreamController<KernelEvent>.broadcast(sync: true);
    addTearDown(live.close);
    final session = _session(live.stream);
    var reads = 0;
    var seq = 0;
    for (var i = 0; i < 128; i++) {
      live.add(ItemUpserted(++seq, 'tool$i', _CountedRead(() => reads++)));
    }
    live.add(ItemUpserted(++seq, 'say', const AssistantTextItem('a')));
    final files = session.filesSeen;
    final before = reads;
    expect(before, greaterThanOrEqualTo(128));
    for (var i = 0; i < 20; i++) {
      live.add(TextDelta(++seq, 'say', i + 1, 'b'));
      expect(session.filesSeen, same(files));
    }
    live.add(ItemUpserted(++seq, 'say', const AssistantTextItem('done')));
    expect(session.filesSeen, same(files));
    live.add(ItemCompleted(++seq, 'say', item: const AssistantTextItem('end')));
    expect(session.filesSeen, same(files));
    live.add(ActivityReported(++seq, null));
    expect(session.filesSeen, same(files));
    expect(reads, before);
  });

  test(
    'file sources update on replacement, completion, history and rewind',
    () {
      final live = StreamController<KernelEvent>.broadcast(sync: true);
      addTearDown(live.close);
      final session = _session(live.stream);
      live.add(
        const ItemUpserted(
          1,
          'tool',
          ToolCallItem(kind: ToolKind.read, target: 'a', path: 'a.dart'),
        ),
      );
      expect(session.filesSeen, [path('a.dart')]);
      live.add(
        const ItemCompleted(
          2,
          'tool',
          item: ToolCallItem(
            kind: ToolKind.read,
            target: 'b',
            path: 'b.dart',
            imageFiles: ['image.png'],
          ),
        ),
      );
      expect(session.filesSeen, [path('b.dart'), path('image.png')]);
      live.add(const ItemUpserted(3, 'tool', AssistantTextItem('replaced')));
      expect(session.filesSeen, isEmpty);
      live.add(
        const HistoryPrepended(4, [
          (
            'old',
            ToolCallItem(kind: ToolKind.read, target: 'old', path: 'old.dart'),
          ),
        ]),
      );
      expect(session.filesSeen, [path('old.dart')]);
      live.add(const ItemRemoved(5, 'old'));
      expect(session.filesSeen, isEmpty);
      live.add(
        const ItemUpserted(
          6,
          'tool',
          ToolCallItem(kind: ToolKind.read, target: 'new', path: 'new.dart'),
        ),
      );
      expect(session.filesSeen, [path('new.dart')]);
      live.add(const Rewound(7, itemId: 'tool'));
      expect(session.filesSeen, isEmpty);
    },
  );

  test("each change pending with its turn and what the turn was asked", () {
    final live = StreamController<KernelEvent>.broadcast(sync: true);
    addTearDown(live.close);
    final session = _session(live.stream);
    live.add(
      const ItemUpserted(
        1,
        't1',
        UserMessageItem(text: 'Fix the login\nplease'),
      ),
    );
    live.add(
      const FileEdited(
        2,
        FileChange(path: 'a.dart', added: 1, removed: 0),
        turnId: 't1',
      ),
    );
    expect(session.turnEdits, [
      (turn: 't1', request: 'Fix the login\nplease', path: path('a.dart')),
    ]);
  });
}
