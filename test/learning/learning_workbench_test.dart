import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/side_panel/side_panel_controller.dart';
import 'package:baocode/chat/side_panel/side_panel_view.dart';
import 'package:baocode/ide/ide_notifications.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/learning/learning_panel.dart';
import 'package:baocode/learning/learning_models.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/workbench_theme.dart';

import '../ide/workbench/fake_files.dart';
import 'learning_visual_fonts.dart';

LearningCard visibleRangeLesson() => LearningCard(
  id: 'synthetic-visible-range',
  title: '只为可见的列表行构建界面',
  summary: '代码把全量范围计算换成 viewport 提供的惰性范围。',
  why: '这可能是为了减少滚动时的重复计算；列表很大时，避免逐项扫描尤其重要。',
  concept: '虚拟列表的工作量应尽量随屏幕可见内容增长，而不是随全部数据量增长。',
  tradeoff: '仍需维护完整的滚动范围，并验证动态行高变化时的位置是否稳定。',
  example: '十万条数据不必同时构建；先构建当前屏幕附近需要显示的行。',
  evidence: const [
    LearningEvidence(
      id: 'synthetic-main-diff',
      kind: 'diff',
      label: 'main.dart',
      path: '/synthetic/lib/main.dart',
      excerpt: '- final visibleRange = calculateRange(scrollOffset);\n+ final visibleRange = viewport.lazyRange(scrollOffset);',
    ),
  ],
  createdAt: DateTime(2026, 1, 1),
);

void main() {
  setUpAll(loadLearningVisualFonts);
  for (final theme in ['Bao Dark', 'Bao Light']) {
    for (final width in [1200.0, 600.0]) {
      learningWidgetTest('learning host synthetic $theme $width', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        WorkbenchThemeService.instance.restore(setting: theme);
        await tester.runAsync(WorkbenchThemeService.instance.initialize);
        final session = ChatSession(
          historyCount: 8,
          kernelContext: const KernelContext(cwd: '/synthetic'),
          openReview: (root, {session}) async => null,
        );
        final panel = AgentSidePanel();
        addTearDown(session.dispose);
        addTearDown(panel.dispose);
        panel.showSection(session, SidePanelSection.learning);
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(),
            locale: const Locale('zh'),
            supportedLocales: const [Locale('zh')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Material(
              child: AgentSidePanelArea(
                panel: panel,
                widthConversation: session,
                builder: (context) => AgentSidePanelView(
                  panel: panel,
                  session: session,
                  learningBuilder: width == 1200
                      ? (_) => LearningPanel(
                          cards: [visibleRangeLesson()],
                          enabled: true,
                          modelLabel: '合成教学模型 · 无网络请求',
                          onConfigure: () {},
                          onTogglePause: () {},
                          onDisable: () {},
                          onOpenEvidence: (_) {},
                        )
                      : null,
                  files: TreeFiles({
                    '/synthetic/lib/main.dart': 'void main() {}',
                  }),
                  notifications: IdeNotifications(),
                  watchDirectory: (_) => const Stream.empty(),
                ),
                child: ChatScreen(session: session),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(LearningPanel), findsOneWidget);
        expect(session.learning.enabled, isFalse);
        expect(session.learning.requestCount, 0);
        expect(tester.takeException(), isNull);
        if (width == 1200) {
          final expand = find.byKey(
            const Key('learning-expand-synthetic-visible-range'),
          );
          await tester.ensureVisible(expand);
          await tester.pumpAndSettle();
          await tester.tap(expand);
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
        }
        if (const bool.fromEnvironment('BAOCODE_LEARNING_VISUALS')) {
          await tester.runAsync(() async {
            final image = await captureImage(tester.binding.rootElement!);
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            File(
                'build/learning-visuals/host-${theme.replaceAll(' ', '-')}-${width.toInt()}.png',
              )
              ..createSync(recursive: true)
              ..writeAsBytesSync(png!.buffer.asUint8List());
            image.dispose();
          });
        }
        panel.showSection(session, SidePanelSection.changes);
        await tester.pumpAndSettle();
        expect(find.byType(LearningPanel), findsNothing);
        expect(session.learning.requestCount, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
