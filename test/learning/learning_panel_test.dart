import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/learning/learning_models.dart';
import 'package:baocode/learning/learning_panel.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/workbench_theme.dart';

// All content is deliberately synthetic. No workspace files or providers are read.
List<LearningCard> fixtures() => List.generate(
  8,
  (i) => LearningCard(
    id: 'synthetic-$i',
    title: 'Cancel stale search results',
    summary: 'The request now checks its generation before updating the view.',
    why: 'An older response can arrive after a newer search. The observed guard prevents that response from replacing current results.',
    concept: 'Asynchronous completion order is not necessarily request order.',
    tradeoff:
        'Ignoring stale results is not the same as cancelling network work.',
    example:
        'Search A starts, then B starts. If A finishes last, keep B visible.',
    evidence: const [],
    createdAt: DateTime(2026, 1, 1, 12, i),
  ),
);

void main() {
  Future<void> pump(
    WidgetTester tester, {
    double width = 360,
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
        home: Scaffold(
          backgroundColor: AppColors.background,
          body: LearningPanel(
            cards: cards ?? fixtures(),
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

  for (final theme in ['Bao Dark', 'Bao Light']) {
    for (final width in [280.0, 360.0, 440.0]) {
      testWidgets('synthetic visual $theme $width', (tester) async {
        addTearDown(tester.view.reset);
        WorkbenchThemeService.instance.restore(setting: theme);
        await WorkbenchThemeService.instance.initialize();
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
