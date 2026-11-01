import 'learning_visual_fonts.dart';

import 'package:baocode/chat/side_panel/side_panel_controller.dart';
import 'package:baocode/chat/side_panel/side_panel_view.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('learning width is independent, bounded and persisted', () {
    final session = Object();
    final panel = AgentSidePanel();
    addTearDown(panel.dispose);
    panel.tabsOf(session).section = SidePanelSection.learning;
    expect(panel.widthFor(session), 360);
    expect(panel.width, 640);
    panel.setWidthFor(session, 450);
    panel.width = 820;
    final restored = AgentSidePanel(state: panel.toJson());
    addTearDown(restored.dispose);
    restored.tabsOf(session).section = SidePanelSection.learning;
    expect(restored.widthFor(session), 450);
    expect(restored.width, 820);
    panel.setWidthFor(session, 900);
    expect(panel.widthFor(session), 480);
    panel.setWidthFor(session, 100);
    expect(panel.widthFor(session), 280);
    panel.setWidthFor(session, double.nan);
    expect(panel.widthFor(session), 280);
    panel.resetWidthFor(session);
    expect(panel.widthFor(session), 360);
    expect(panel.width, 820);
    panel.tabsOf(session).section = SidePanelSection.changes;
    expect(panel.widthFor(session), 820);
  });

  test('old state and invalid learning widths keep safe defaults', () {
    for (final state in [
      <String, Object?>{'width': 720},
      <String, Object?>{'width': 720, 'learningWidth': double.infinity},
    ]) {
      final panel = AgentSidePanel(state: state);
      addTearDown(panel.dispose);
      final session = Object();
      panel.tabsOf(session).section = SidePanelSection.learning;
      expect(panel.widthFor(session), 360);
      expect(panel.widthFor(null), 720);
    }
  });

  learningWidgetTest(
    'window panel uses focused section without pane visibility',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final session = Object();
      final panel = AgentSidePanel();
      addTearDown(panel.dispose);
      panel.showSection(session, SidePanelSection.learning);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Material(
            child: AgentSidePanelArea(
              panel: panel,
              widthConversation: session,
              builder: (_) =>
                  const SizedBox.expand(key: ValueKey('learning-content')),
              child: const SizedBox.expand(
                key: ValueKey('conversation-content'),
              ),
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('learning-content'))).width,
        360,
      );
      expect(panel.shown, isTrue);
      final sash = find.byKey(const ValueKey('side-panel-sash'));
      await tester.drag(sash, const Offset(-60, 0));
      await tester.pumpAndSettle();
      expect(panel.widthFor(session), 420);
      expect(panel.width, 640);
      panel.showSection(session, SidePanelSection.changes);
      await tester.pump();
      expect(
        tester.getSize(find.byKey(const ValueKey('learning-content'))).width,
        640,
      );
      panel.showSection(session, SidePanelSection.learning);
      tester.view.physicalSize = const Size(600, 500);
      await tester.pump();
      await tester.pump(AgentSidePanelArea.overlayDelay);
      await tester.pump();
      expect(find.byKey(const ValueKey('scrim')), findsOneWidget);
      expect(tester.takeException(), isNull);
      panel.hide();
      await tester.pump();
      expect(find.byKey(const ValueKey('learning-content')), findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey('conversation-content'))),
        const Size(600, 500),
      );
    },
  );
}
