import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/learning/work_trace.dart';
import 'package:baocode/learning/work_trace_panel.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('trace retains only bounded observed facts and exact operation IDs', () {
    final trace = WorkTraceController();
    addTearDown(trace.dispose);
    trace.accept(const TurnStarted(1, 'turn'));
    trace.accept(
      const ItemUpserted(
        2,
        'read',
        ToolCallItem(kind: ToolKind.read, target: 'private'),
      ),
    );
    trace.accept(
      const ItemUpserted(
        3,
        'thought',
        ThinkingItem(text: 'private reasoning', tokens: 2),
      ),
    );
    trace.accept(
      const ItemUpserted(
        4,
        'diff',
        CodeDiffItem(fileName: 'a.dart', directory: '', lines: []),
      ),
    );
    expect(trace.entries.single.label, 'Read private');
    trace.accept(
      const FileEdited(
        5,
        FileChange(path: 'lib/a.dart', added: 1, removed: 2),
        turnId: 'turn',
        sourceItemId: 'diff',
      ),
    );
    expect(trace.entries.last.sourceItemId, 'diff');
    expect(trace.entries.last.label, 'a.dart');
    for (var i = 6; i < 110; i++) {
      trace.accept(
        ItemUpserted(
          i,
          'command-$i',
          const TerminalItem(
            command: 'echo synthetic',
            output: 'private output',
            status: CommandStatus.succeeded,
          ),
        ),
      );
    }
    expect(trace.entries, hasLength(80));
    expect(trace.omittedCount, 26);
    expect(trace.entries.last.status, WorkTraceStatus.completed);
    expect(trace.entries.last.label, isEmpty);
  });

  test(
    'terminal completion does not invent test success; denial is explicit',
    () {
      final trace = WorkTraceController();
      addTearDown(trace.dispose);
      trace.accept(const TurnStarted(1, 'turn'));
      trace.accept(
        const ItemUpserted(
          2,
          'command',
          TerminalItem(
            command: 'test',
            output: '',
            status: CommandStatus.running,
          ),
        ),
      );
      trace.accept(
        const ItemUpserted(
          3,
          'denied',
          ToolCallItem(
            kind: ToolKind.edit,
            target: 'a.dart',
            status: ToolStatus.denied,
          ),
        ),
      );
      trace.accept(const TurnEnded(4, 'turn', interrupted: true));
      expect(trace.entries.first.status, WorkTraceStatus.unknown);
      expect(trace.entries.last.status, WorkTraceStatus.denied);
      expect(trace.interrupted, isTrue);
      trace.accept(
        const ItemCompleted(
          5,
          'command',
          item: TerminalItem(
            command: 'test',
            output: '',
            status: CommandStatus.succeeded,
          ),
        ),
      );
      expect(trace.entries.first.status, WorkTraceStatus.completed);
      trace.accept(const TurnStarted(6, 'next'));
      expect(trace.entries, isEmpty);
      trace.accept(
        const FileEdited(
          7,
          FileChange(path: 'old', added: 1, removed: 0),
          turnId: 'turn',
        ),
      );
      expect(trace.entries, isEmpty);
    },
  );

  test(
    'updates coalesce and incoming repeated sequence cannot change trace',
    () {
      final trace = WorkTraceController();
      addTearDown(trace.dispose);
      var notifications = 0;
      trace.addListener(() => notifications++);
      trace.accept(const TurnStarted(1, 'turn'));
      const command = TerminalItem(
        command: 'private',
        output: '',
        status: CommandStatus.running,
      );
      trace.accept(const ItemUpserted(2, 'command', command));
      trace.accept(const ItemUpserted(3, 'command', command));
      expect(notifications, 2);
      trace.accept(const ItemRemoved(2, 'command'));
      expect(trace.entries, hasLength(1));
      trace.accept(const ItemRemoved(4, 'command'));
      expect(trace.entries, isEmpty);
    },
  );

  test('kernel replacement clears sequence state and minimizes labels', () {
    final trace = WorkTraceController();
    addTearDown(trace.dispose);
    trace.accept(const TurnStarted(80, 'old'));
    trace.reset();
    trace.accept(const TurnStarted(1, 'fresh'));
    trace.accept(
      const ItemUpserted(
        2,
        'task',
        AgentItem(
          description: 'Build token=super-secret',
          prompt: 'private prompt',
          result: 'private result',
        ),
      ),
    );
    expect(trace.currentTurnId, 'fresh');
    expect(trace.entries.single.label, isNot(contains('super-secret')));
    expect(trace.entries.single.label, contains('[REDACTED]'));
  });

  test(
    'null completion resolves one supplied item; tokens do not rebuild trace',
    () {
      final trace = WorkTraceController();
      addTearDown(trace.dispose);
      var notifications = 0;
      trace.addListener(() => notifications++);
      trace.accept(const TurnStarted(1, 'turn'));
      trace.accept(
        const ItemUpserted(
          2,
          'command',
          TerminalItem(
            command: 'synthetic',
            output: '',
            status: CommandStatus.running,
          ),
        ),
      );
      trace.accept(
        const ItemCompleted(3, 'command'),
        completedItem: const TerminalItem(
          command: 'synthetic',
          output: '',
          status: CommandStatus.failed,
        ),
      );
      expect(trace.entries.single.status, WorkTraceStatus.failed);
      expect(notifications, 3);
      for (var seq = 4; seq < 10004; seq++) {
        trace.accept(TextDelta(seq, 'text', seq, 'private streamed text'));
      }
      expect(notifications, 3);
      expect(trace.entries, hasLength(1));
      trace.accept(const ItemCompleted(10004, 'command'));
      expect(trace.entries.single.status, WorkTraceStatus.failed);
      expect(notifications, 3);
    },
  );

  test('narrative snapshots are bounded cached facts without denied or sensitive context', () {
    final trace = WorkTraceController();
    addTearDown(trace.dispose);
    trace.accept(const TurnStarted(1, 'turn'));
    trace.accept(
      const ItemUpserted(
        2,
        'env',
        ToolCallItem(
          kind: ToolKind.read,
          target: '.env',
          path: '/synthetic/.env',
          output: 'TOKEN=private',
        ),
      ),
    );
    trace.accept(
      const ItemUpserted(
        3,
        'command',
        TerminalItem(command: 'printenv', output: 'private environment'),
      ),
    );
    trace.accept(
      const ItemUpserted(
        4,
        'denied',
        ToolCallItem(
          kind: ToolKind.edit,
          target: 'a.dart',
          label: 'private denied action',
          status: ToolStatus.denied,
        ),
      ),
    );
    trace.accept(
      const ItemUpserted(
        5,
        'thought',
        ThinkingItem(text: 'private thought', tokens: 1),
      ),
    );
    trace.accept(
      const FileEdited(
        6,
        FileChange(path: '/synthetic/secrets/config', added: 1, removed: 0),
        sourceItemId: 'private-file',
      ),
    );
    expect(trace.narrativeSnapshot!.facts, isEmpty);
    for (var i = 7; i < 27; i++) {
      trace.accept(
        ItemUpserted(
          i,
          'read-$i',
          ToolCallItem(
            kind: ToolKind.read,
            target: 'script-$i.ps1',
            path: '/synthetic/script-$i.ps1',
          ),
        ),
      );
    }
    final snapshot = trace.narrativeSnapshot!;
    expect(snapshot.facts, hasLength(12));
    expect(snapshot.facts.first.sourceItemId, 'read-7');
    expect(snapshot.omittedCount, 8);
    expect(snapshot.facts.last.sourceItemId, 'read-26');
    expect(snapshot.facts.last.label, 'Read script-26.ps1');
    expect(identical(trace.narrativeSnapshot, snapshot), isTrue);
    trace.accept(const TextDelta(27, 'text', 0, 'private'));
    expect(identical(trace.narrativeSnapshot, snapshot), isTrue);
    trace.accept(const ItemRemoved(28, 'read-26'));
    expect(trace.narrativeSnapshot!.revision, greaterThan(snapshot.revision));
    expect(
      trace.narrativeSnapshot!.facts.any((f) => f.id == 'read-26'),
      isFalse,
    );
    trace.accept(
      const ItemUpserted(
        29,
        'read-25',
        ToolCallItem(
          kind: ToolKind.read,
          target: '.env',
          path: '/synthetic/.env',
        ),
      ),
    );
    expect(
      trace.narrativeSnapshot!.facts.any((f) => f.id == 'read-25'),
      isFalse,
    );
    trace.accept(const ChangesReverted(30));
    expect(trace.narrativeSnapshot!.facts, isEmpty);
  });

  test('new turns exclude late updates for known previous-turn operations', () {
    final trace = WorkTraceController();
    addTearDown(trace.dispose);
    trace.accept(const TurnStarted(1, 'one'));
    trace.accept(
      const ItemUpserted(
        2,
        'old',
        TerminalItem(
          command: 'synthetic',
          output: '',
          status: CommandStatus.running,
        ),
      ),
    );
    trace.accept(const TurnStarted(3, 'two'));
    trace.accept(
      const ItemCompleted(
        4,
        'old',
        item: TerminalItem(command: 'synthetic', output: ''),
      ),
    );
    expect(trace.narrativeSnapshot!.turnId, 'two');
    expect(trace.narrativeSnapshot!.facts, isEmpty);
  });

  for (final width in [280.0, 360.0]) {
    testWidgets('trace wraps at $width and jumps only to exact source', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final trace = WorkTraceController();
      addTearDown(trace.dispose);
      trace.accept(const TurnStarted(1, 'turn'));
      trace.accept(
        const FileEdited(
          2,
          FileChange(path: 'lib/synthetic.dart', added: 4, removed: 2),
          sourceItemId: 'exact-operation',
        ),
      );
      String? opened;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Material(
            child: WorkTracePanel(
              controller: trace,
              onOpenItem: (id) => opened = id,
            ),
          ),
        ),
      );
      expect(find.text('Work trace'), findsOneWidget);
      expect(find.text('synthetic.dart'), findsNothing);
      await tester.tap(find.byKey(const Key('work-trace-evidence')));
      await tester.pump();
      expect(find.text('synthetic.dart'), findsOneWidget);
      await tester.ensureVisible(find.text('View operation'));
      await tester.tap(find.text('View operation'));
      expect(opened, 'exact-operation');
      expect(tester.takeException(), isNull);
      trace.accept(const TurnStarted(3, 'next'));
      await tester.pump();
      expect(find.text('synthetic.dart'), findsNothing);
      expect(find.text('synthetic.dart'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
