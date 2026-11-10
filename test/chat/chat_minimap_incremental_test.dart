import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/widgets/chat_minimap.dart';
import 'package:baocode/theme/app_theme.dart';

class _Harness {
  final moved = ChangeNotifier();
  final rows = <ChatItem>[
    for (var i = 0; i < 40; i++) AssistantTextItem('Row $i\n\nParagraph $i'),
  ];
  final reads = <int>[];
  final seeks = <(int, double)>[];
  int revision = 0;
  int changedFrom = 0;
  bool narrow = false;
  Key key = const ValueKey('cached');

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: ChatMinimap(
              key: key,
              rowCount: rows.length,
              rowAt: (i) {
                reads.add(i);
                return (item: rows[i], shown: true, foldLines: 0, gap: 0);
              },
              revision: revision,
              changedFrom: changedFrom,
              span: () => (first: 0, firstAt: 0, last: 1, lastAt: 1),
              moved: moved,
              columnIn: (_) => (left: narrow ? 0.0 : 120.0, width: 400.0),
              long: true,
              scrolling: () => false,
              onSeek: (index, fraction) => seeks.add((index, fraction)),
              onSeekEnd: () => seeks.add((-1, 1)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Rect track(WidgetTester tester) => tester.getRect(
    find.descendant(
      of: find.byType(ChatMinimap),
      matching: find.byType(CustomPaint),
    ),
  );

  Future<List<(int, double)>> probe(WidgetTester tester) async {
    seeks.clear();
    final rect = track(tester);
    for (final fraction in [0.15, 0.4, 0.7]) {
      await tester.tapAt(
        Offset(rect.center.dx, rect.top + rect.height * fraction),
      );
      await tester.pumpAndSettle();
    }
    expect(seeks, hasLength(3));
    return [...seeks];
  }

  Future<void> expectFreshSeek(WidgetTester tester) async {
    final incremental = await probe(tester);
    key = UniqueKey();
    await pump(tester);
    final fresh = await probe(tester);
    for (var i = 0; i < fresh.length; i++) {
      expect(incremental[i].$1, fresh[i].$1);
      expect(incremental[i].$2, closeTo(fresh[i].$2, 0.000001));
    }
  }
}

void main() {
  testWidgets('unchanged revision skips parent rebuild and hover sampling', (
    tester,
  ) async {
    final h = _Harness();
    addTearDown(h.moved.dispose);
    await h.pump(tester);
    expect(h.reads, List.generate(40, (i) => i));
    h.reads.clear();
    await h.pump(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(h.track(tester).center);
    await tester.pumpAndSettle();
    await mouse.moveTo(Offset.zero);
    await mouse.removePointer();
    await tester.pumpAndSettle();
    expect(h.reads, isEmpty);
  });

  testWidgets(
    'tail revision samples only changed suffix and seeks like fresh',
    (tester) async {
      final h = _Harness();
      addTearDown(h.moved.dispose);
      await h.pump(tester);
      h.reads.clear();
      h.rows[38] = AssistantTextItem('New paragraph\n\n' * 20);
      h.revision++;
      h.changedFrom = 38;
      await h.pump(tester);
      expect(h.reads, [38, 39]);
      await h.expectFreshSeek(tester);
    },
  );

  testWidgets('hidden narrow layout coalesces early and late dirty ranges', (
    tester,
  ) async {
    final h = _Harness();
    addTearDown(h.moved.dispose);
    await h.pump(tester);
    h.narrow = true;
    await h.pump(tester);
    h.reads.clear();
    h.rows[2] = AssistantTextItem('Early changed paragraph\n\n' * 30);
    h.revision++;
    h.changedFrom = 2;
    await h.pump(tester);
    h.rows[38] = const AssistantTextItem('Late changed paragraph');
    h.revision++;
    h.changedFrom = 38;
    await h.pump(tester);
    expect(h.reads, isEmpty);
    h.narrow = false;
    await h.pump(tester);
    expect(h.reads, List.generate(38, (i) => i + 2));
    await h.expectFreshSeek(tester);
  });

  testWidgets(
    'prepend and truncation rescan structure and retain correct seek',
    (tester) async {
      final h = _Harness();
      addTearDown(h.moved.dispose);
      await h.pump(tester);
      h.reads.clear();
      h.rows.insert(0, AssistantTextItem('Prepended text\n\n' * 15));
      // Count changes override even a stale revision and suffix hint.
      h.changedFrom = 39;
      await h.pump(tester);
      expect(h.reads, List.generate(41, (i) => i));
      await h.expectFreshSeek(tester);
      h.reads.clear();
      h.rows.removeRange(20, h.rows.length);
      await h.pump(tester);
      expect(h.reads, List.generate(20, (i) => i));
      await h.expectFreshSeek(tester);
    },
  );
}
