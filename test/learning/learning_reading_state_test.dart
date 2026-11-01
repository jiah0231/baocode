import 'package:baocode/learning/learning_models.dart';
import 'package:baocode/learning/learning_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<LearningCard> _cards() => List.generate(
  8,
  (i) => LearningCard(
    id: 'reading-$i',
    title: 'Synthetic operation $i',
    summary: 'A completed operation with a useful observation.',
    why: 'This may prevent stale results from replacing a newer request.',
    concept: 'Takeaway $i: completion order differs from request order.',
    evidence: const [],
    createdAt: DateTime(2026, 1, 1),
  ),
);

void main() {
  Future<void> pumpPanel(
    WidgetTester tester,
    LearningReadingState state, {
    String session = 'session-a',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 700,
            child: LearningPanel(
              readingState: state,
              sessionKey: session,
              cards: _cards(),
              enabled: true,
              onConfigure: () {},
              onTogglePause: () {},
              onDisable: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'file preview round trip retains reading position and selections',
    (tester) async {
      final state = LearningReadingState();
      await pumpPanel(tester, state);
      await tester.tap(find.byKey(const Key('learning-recap')));
      await tester.pumpAndSettle();
      final expand = find.byKey(const Key('learning-expand-reading-0'));
      await tester.ensureVisible(expand);
      await tester.tap(expand);
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('learning-scroll')),
        const Offset(0, -180),
      );
      await tester.pumpAndSettle();
      final offset = state.scrollOffset;
      expect(offset, greaterThan(0));
      expect(state.following, isFalse);
      expect(state.recapExpanded, isTrue);
      expect(state.expandedIds, contains('reading-0'));

      // The same rail is replaced by a read-only file, disposing the panel.
      await tester.pumpWidget(
        const MaterialApp(home: Text('Synthetic file preview')),
      );
      await tester.pumpAndSettle();
      await pumpPanel(tester, state);
      final list = tester.widget<ListView>(
        find.byKey(const Key('learning-scroll')),
      );
      expect(list.controller!.offset, closeTo(offset, 1));
      expect(state.recapExpanded, isTrue);
      expect(state.expandedIds, contains('reading-0'));
      expect(find.byKey(const Key('learning-follow-latest')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mounted session changes keep reading state isolated', (
    tester,
  ) async {
    final first = LearningReadingState();
    final second = LearningReadingState();
    await pumpPanel(tester, first);
    await tester.tap(find.byKey(const Key('learning-expand-reading-0')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('learning-scroll')),
      const Offset(0, -150),
    );
    await tester.pumpAndSettle();
    final offset = first.scrollOffset;

    await pumpPanel(tester, second, session: 'session-b');
    expect(second.expandedIds, isEmpty);
    expect(second.following, isTrue);
    expect(second.recapExpanded, isFalse);
    expect(second.scrollOffset, 0);
    expect(find.byKey(const Key('learning-follow-latest')), findsNothing);
    expect(first.expandedIds, contains('reading-0'));

    await pumpPanel(tester, first);
    expect(first.scrollOffset, closeTo(offset, 1));
    expect(first.expandedIds, contains('reading-0'));
    expect(first.following, isFalse);
    expect(tester.takeException(), isNull);
  });
}
