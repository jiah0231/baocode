import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_column.dart';
import 'package:baocode/chat/widgets/edit_step.dart';
import 'package:baocode/learning/learning_bubble.dart';
import 'package:baocode/learning/learning_models.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/workbench_theme.dart';

import 'learning_visual_fonts.dart';

// Synthetic reconstruction of the reference's layout, not private source code.
const teachingDiff = CodeDiffItem(
  fileName: 'tm_diag2.ps1',
  directory: 'synthetic',
  lines: [
    DiffLine(
      DiffLineType.context,
      1,
      '[Console]::OutputEncoding = [Text.Encoding]::UTF8',
    ),
    DiffLine(DiffLineType.removed, 2, 'Write-Output "任务管理器相关日志"'),
    DiffLine(
      DiffLineType.added,
      2,
      'Write-Output "Taskmgr-related Application events"',
    ),
    DiffLine(
      DiffLineType.removed,
      3,
      r'$ev = Get-WinEvent -LogName Application',
    ),
    DiffLine(
      DiffLineType.added,
      3,
      r'$ev = Get-WinEvent -LogName Application -MaxEvents 200',
    ),
    DiffLine(DiffLineType.context, 4, r'if ($ev) {'),
    DiffLine(
      DiffLineType.context,
      5,
      r'  $ev | Select-Object TimeCreated, Id, Message',
    ),
    DiffLine(DiffLineType.context, 6, '}'),
  ],
);
LearningCard bubbleLesson() => LearningCard(
  id: 'synthetic-diagnostic',
  title: '限制查询范围',
  summary: '这一步调整了输出标题，并给日志查询增加了数量上限。',
  why: '这可能是为了避免一次读取过多日志。英文标题也可能减少终端编码差异带来的显示问题，但不能据此断言故障已经修复。',
  concept: '限制结果数量能降低查询成本，但也可能漏掉更早的事件。',
  tradeoff: '需要更长时间范围时，应明确指定查询条件，而不是只增加上限。',
  evidence: const [
    LearningEvidence(
      id: 'synthetic-diagnostic',
      kind: 'diff',
      label: 'tm_diag2.ps1',
      sourceItemId: 'synthetic-diagnostic',
      path: 'synthetic/tm_diag2.ps1',
      excerpt: '+ Get-WinEvent -LogName Application -MaxEvents 200',
    ),
  ],
  createdAt: DateTime(2026, 1, 1),
);
Future<void> captureBubble(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('BAOCODE_LEARNING_VISUALS')) return;
  await tester.runAsync(() async {
    final image = await captureImage(tester.binding.rootElement!);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/learning-visuals/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(loadLearningVisualFonts);
  test('annotation gutter preserves main column left and viewport bounds', () {
    final plain = RenderChatColumn.place(1200, maxWidth: 720);
    final annotated = RenderChatColumn.place(
      1200,
      maxWidth: 720,
      trailing: 260,
    );
    expect(plain, (left: 240.0, width: 720.0));
    expect(annotated, (left: 240.0, width: 960.0));
    expect(
      RenderChatColumn.place(1200, maxWidth: 720, right: 100, trailing: 260),
      (left: 240.0, width: 860.0),
    );
  });
  learningWidgetTest(
    'bubble absence preserves operation and resize preserves state',
    (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1120, 850);
      var enabled = false;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Scaffold(
                body: LearningOperationExplanation(
                  enabled: enabled,
                  card: bubbleLesson(),
                  child: const TextField(),
                ),
              );
            },
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'keep my operation state');
      expect(find.byType(LearningBubble), findsNothing);
      update(() => enabled = true);
      await tester.pumpAndSettle();
      expect(find.byType(LearningBubble), findsOneWidget);
      tester.view.physicalSize = const Size(600, 850);
      await tester.pumpAndSettle();
      expect(find.text('keep my operation state'), findsOneWidget);
      expect(
        find.byKey(const Key('learning-operation-stacked')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  learningWidgetTest(
    'collapsed long rationale is glanceable and expands fully',
    (tester) async {
      final why = List.filled(30, '这只是依据可见改动推测的原因，意图尚不确定。').join();
      final base = bubbleLesson();
      final card = LearningCard(
        id: base.id,
        title: base.title,
        summary: base.summary,
        why: why,
        concept: base.concept,
        evidence: base.evidence,
        createdAt: base.createdAt,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(width: 240, child: LearningBubble(card: card)),
            ),
          ),
        ),
      );
      final body = tester
          .widgetList<Text>(find.byType(Text))
          .firstWhere((text) => text.data?.startsWith('这只是') == true);
      expect(body.maxLines, 4);
      expect(body.overflow, TextOverflow.ellipsis);
      await tester.tap(
        find.byKey(const Key('learning-bubble-expand-synthetic-diagnostic')),
      );
      await tester.pumpAndSettle();
      expect(find.text(why), findsOneWidget);
      expect(tester.widget<Text>(find.text(why)).maxLines, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  for (final theme in ['Bao Dark', 'Bao Light']) {
    for (final width in [1120.0, 600.0]) {
      learningWidgetTest('operation bubble $theme $width', (tester) async {
        tester.view.physicalSize = Size(width, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        WorkbenchThemeService.instance.restore(setting: theme);
        await tester.runAsync(WorkbenchThemeService.instance.initialize);
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(),
            locale: const Locale('zh'),
            supportedLocales: const [Locale('zh')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('合成演示 · 已完成诊断脚本修改'),
                      const SizedBox(height: 12),
                      LearningOperationExplanation(
                        card: bubbleLesson(),
                        child: const EditStep(item: teachingDiff),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(EditStep), findsOneWidget);
        expect(
          find.byKey(
            Key(
              width >= 800
                  ? 'learning-operation-row'
                  : 'learning-operation-stacked',
            ),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        final prefix = 'inline-${theme.replaceAll(' ', '-')}-${width.toInt()}';
        await captureBubble(tester, prefix);
        final expand = find.byKey(
          const Key('learning-bubble-expand-synthetic-diagnostic'),
        );
        await tester.ensureVisible(expand);
        await tester.tap(expand);
        await tester.pumpAndSettle();
        expect(find.text(bubbleLesson().concept), findsOneWidget);
        expect(tester.takeException(), isNull);
        await captureBubble(tester, '$prefix-expanded');
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
