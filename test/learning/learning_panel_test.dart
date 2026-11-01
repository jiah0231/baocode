import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'learning_visual_fonts.dart';

import 'package:baocode/learning/learning_models.dart';
import 'package:baocode/learning/learning_panel.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/workbench_theme.dart';

// All content is deliberately synthetic. No workspace files or providers are read.
List<LearningCard> fixtures({bool chinese = false}) {
  final titles = chinese
      ? ['取消过期的搜索结果', '把多次更新合并处理', '部署前验证模型接口']
      : [
          'Cancel stale search results',
          'Coalesce repeated updates',
          'Check the model endpoint before deployment',
        ];
  final summaries = chinese
      ? ['更新视图前先检查请求代次。', '短时间内的事件现在合并成一次界面更新。', '配置中新增了模型接口地址，但还没有部署成功的证据。']
      : [
          'The request checks its generation before updating the view.',
          'Nearby events now share one UI update.',
          'A model endpoint was added; this record does not prove deployment succeeded.',
        ];
  final concepts = chinese
      ? [
          '异步任务的完成顺序不一定等于发起顺序。',
          '合并事件可以减少重复计算，但会引入少量等待时间。',
          '配置完成不等于服务可用，仍需要独立验证。',
        ]
      : [
          'Asynchronous completion order is not necessarily request order.',
          'Batching reduces repeated work at the cost of a small delay.',
          'Configuration is not verification: readiness needs independent evidence.',
        ];
  return List.generate(
    3,
    (i) => LearningCard(
      id: 'synthetic-$i',
      title: titles[i],
      summary: summaries[i],
      why: chinese ? '这可能是在避免重复或过期的操作；仅凭当前片段无法确认作者的实际意图。' : 'This may avoid redundant or stale work; the excerpt cannot establish the author’s intent.',
      concept: concepts[i],
      tradeoff: chinese
          ? '更保守的处理方式可能增加等待时间。'
          : 'A more conservative check may add latency.',
      example: chinese
          ? '先发起 A，再发起 B；A 最后完成时仍保留 B。'
          : 'Start A, then B. If A finishes last, keep B visible.',
      evidence: [
        LearningEvidence(
          id: 'fixture-$i',
          kind: 'diff',
          label: 'synthetic/example_$i.dart',
          excerpt: '+ if (generation != current) return;',
          path: '/synthetic/example_$i.dart',
        ),
      ],
      createdAt: DateTime(2026, 1, 1, 12, i),
    ),
  );
}

void main() {
  setUpAll(loadLearningVisualFonts);
  Future<void> pump(
    WidgetTester tester, {
    double width = 360,
    bool chinese = false,
    bool enabled = true,
    bool busy = false,
    String? error,
    List<LearningCard>? cards,
    VoidCallback? configure,
    VoidCallback? pause,
    VoidCallback? disable,
  }) async {
    tester.view.physicalSize = Size(width, 760);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        locale: Locale(chinese ? 'zh' : 'en'),
        supportedLocales: const [Locale('en'), Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          backgroundColor: AppColors.background,
          body: LearningPanel(
            cards: cards ?? fixtures(chinese: chinese),
            enabled: enabled,
            busy: busy,
            error: error,
            modelLabel: 'Synthetic provider / fixture-model',
            onConfigure: configure ?? () {},
            onTogglePause: pause ?? () {},
            onDisable: disable ?? () {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('disabled rail offers configuration without generating content', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    var configured = 0;
    await pump(
      tester,
      enabled: false,
      cards: [],
      configure: () => configured++,
    );
    expect(find.byKey(const Key('learning-configure')), findsOneWidget);
    await tester.tap(find.byKey(const Key('learning-configure')));
    expect(configured, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cards expand without changing their stable identity', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await pump(tester, cards: fixtures().take(1).toList());
    final expand = find.byKey(const Key('learning-expand-synthetic-0'));
    await tester.tap(expand);
    await tester.pumpAndSettle();
    expect(find.textContaining('Asynchronous completion'), findsOneWidget);
    await tester.ensureVisible(expand);
    await tester.tap(expand);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('learning-card-synthetic-0')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pause and disable controls invoke host without mutating cards', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    var pauses = 0;
    var disables = 0;
    await pump(tester, pause: () => pauses++, disable: () => disables++);
    await tester.tap(find.byKey(const Key('learning-pause')));
    await tester.tap(find.byKey(const Key('learning-disable')));
    expect(pauses, 1);
    expect(disables, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long Chinese explanation keeps full expanded text', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final longText = List.filled(15, '这是一段用于测试换行的合成说明，配置完成不代表服务已经验证。').join();
    await pump(
      tester,
      width: 280,
      chinese: true,
      cards: [
        LearningCard(
          id: 'long',
          title: '较长的中文知识讲解标题',
          summary: longText,
          why: longText,
          concept: '观察证据与推断需要区分。',
          evidence: const [],
          createdAt: DateTime(2026),
        ),
      ],
    );
    await tester.tap(find.byKey(const Key('learning-expand-long')));
    await tester.pumpAndSettle();
    expect(find.text(longText), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Chinese expanded and recap synthetic fixtures', (tester) async {
    addTearDown(tester.view.reset);
    await pump(tester, chinese: true, cards: fixtures(chinese: true));
    await tester.pumpAndSettle();
    for (final state in ['expanded', 'recap']) {
      if (state == 'expanded') {
        final expand = find.byKey(const Key('learning-expand-synthetic-2'));
        await tester.ensureVisible(expand);
        await tester.tap(expand);
      } else {
        final recap = find.byKey(const Key('learning-recap'));
        await tester.ensureVisible(recap);
        await tester.tap(recap);
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('BAOCODE_LEARNING_VISUALS')) {
        await tester.runAsync(() async {
          final image = await captureImage(tester.binding.rootElement!);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File('build/learning-visuals/chinese-$state.png')
            ..createSync(recursive: true)
            ..writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    }
  });

  for (final theme in ['Bao Dark', 'Bao Light']) {
    for (final width in [280.0, 360.0, 440.0]) {
      testWidgets('synthetic visual $theme $width', (tester) async {
        addTearDown(tester.view.reset);
        WorkbenchThemeService.instance.restore(setting: theme);
        await tester.runAsync(WorkbenchThemeService.instance.initialize);
        await pump(tester, width: width);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('BAOCODE_LEARNING_VISUALS')) {
          await tester.runAsync(() async {
            final image = await captureImage(tester.binding.rootElement!);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            File(
                'build/learning-visuals/${theme.replaceAll(' ', '-')}-${width.toInt()}.png',
              )
              ..createSync(recursive: true)
              ..writeAsBytesSync(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await pump(tester, width: width, cards: [], busy: true);
        expect(tester.takeException(), isNull);
        await pump(
          tester,
          width: width,
          cards: [],
          error: 'Synthetic temporary failure',
        );
        expect(tester.takeException(), isNull);
        await pump(tester, width: width, cards: [], enabled: false);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
